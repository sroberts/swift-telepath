import Logging
import Msgpack

/// Resolves `aha://` URLs through the AHA registry, per spec §3.9.
///
/// Every rule here is a reading of `synapse/telepath.py` and `synapse/lib/aha.py`
/// at 2.249.0, not a design. The ones that are easy to get wrong by inference are
/// marked where they apply.
enum AHAResolver {
    /// Synapse gained the `filters` argument to `getAhaSvc` here. Older registries
    /// reject the call outright rather than ignoring it.
    static let filtersMinimumVersion = [2, 95, 0]

    /// Resolves a service name to a directly connectable URL.
    ///
    /// - Parameter open: how to open a proxy to a registry. Injected so the
    ///   resolver can be tested against a scripted daemon without a live AHA.
    static func resolve(
        _ url: TelepathURL,
        registries: [String],
        logger: Logger,
        open: (String) async throws -> Proxy
    ) async throws -> TelepathURL {
        guard let name = url.host, !name.isEmpty else {
            throw TelepathError.invalidURL("\(url)", reason: "aha:// requires a service name")
        }
        // Python keeps registries in a module global and raises NotReady with this
        // shape. A library cannot have a global, so this is the configured list
        // being empty — which is a setup mistake, and says so.
        guard !registries.isEmpty else {
            throw TelepathError.ahaNoRegistries(service: name)
        }

        var lastFailure: (any Error)?
        for registry in registries {
            do {
                let resolved = try await lookup(
                    name: name, from: url, registry: registry, logger: logger, open: open)
                guard let resolved else { continue }   // absent or offline: try the next
                return resolved
            } catch let error as TelepathError {
                // A pool, or a mirror the registry cannot filter for, is a definite
                // answer about this service. Trying the next registry would only
                // produce the same answer more slowly.
                if case .ahaIsAPool = error { throw error }
                if case .ahaMirrorUnsupported = error { throw error }
                logger.warning("aha registry \(registry) failed for \(name): \(error)")
                lastFailure = error
            } catch {
                logger.warning("aha registry \(registry) failed for \(name): \(error)")
                lastFailure = error
            }
        }

        // Falling through every registry is a failure, never an empty success.
        // Python raises the last exception it saw if there was one, and NoSuchName
        // otherwise; the distinction matters because "all your registries are
        // unreachable" and "no registry has heard of this service" want different
        // fixes from whoever reads the error.
        if let lastFailure { throw lastFailure }
        throw TelepathError.ahaLookupFailed(service: name)
    }

    /// One registry's answer. Nil means "this registry cannot serve it" — either it
    /// has never heard of the service, or the service is registered but offline.
    private static func lookup(
        name: String,
        from url: TelepathURL,
        registry: String,
        logger: Logger,
        open: (String) async throws -> Proxy
    ) async throws -> TelepathURL? {
        let registryURL = try TelepathURL(registry)
        guard registryURL.scheme != .aha else {
            throw TelepathError.invalidURL(registry, reason: "an aha registry cannot itself be aha://")
        }

        // Closed on every path rather than in a detached task: the registry
        // connection owns an event loop group, and a fire-and-forget close would
        // outlive the lookup it exists for.
        let proxy = try await open(registry)
        do {
            let resolved = try await ask(proxy, name: name, from: url, registry: registry,
                                         logger: logger)
            await proxy.close()
            return resolved
        } catch {
            await proxy.close()
            throw error
        }
    }

    private static func ask(
        _ proxy: Proxy,
        name: String,
        from url: TelepathURL,
        registry: String,
        logger: Logger
    ) async throws -> TelepathURL? {
        let registryVersion = await proxy.serverVersion

        var kwargs: [String: MsgpackValue] = [:]
        if url.wantsMirror || supportsFilters(registryVersion) {
            guard supportsFilters(registryVersion) else {
                // Sending the argument to an older registry fails the call; dropping
                // it silently would hand back the leader while the caller believes
                // they asked for a mirror.
                throw TelepathError.ahaMirrorUnsupported(
                    registry: registry, version: registryVersion)
            }
            kwargs["filters"] = .map([.string("mirror"): .bool(url.wantsMirror)])
        }

        let reply = try await proxy.call("getAhaSvc", [.string(name)], kwargs: kwargs)
        guard case .map = reply else { return nil }   // None: unknown to this registry

        // A pool is signalled by `services` on the *outer* record, alongside `name`
        // — not inside the nested `svcinfo`. Python names the local variable
        // `svcinfo` at that point, which makes the two easy to confuse.
        if reply["services"] != nil {
            throw TelepathError.ahaIsAPool(name: reply["name"]?.stringValue ?? name)
        }

        guard let svcinfo = reply["svcinfo"] else { return nil }
        // `online` carries an iden rather than a bool. Anything falsy — absent or
        // null — means registered but not currently up, so move on.
        let online = svcinfo["online"]
        if online == nil || online == .null { return nil }

        guard case .map(let rawURLInfo)? = svcinfo["urlinfo"] else { return nil }
        var upstream: [String: MsgpackValue] = [:]
        for (key, value) in rawURLInfo {
            if let key = key.stringValue { upstream[key] = value }
        }
        logger.debug("aha resolved \(name) via \(registry)")
        return try url.mergingAHAInfo(upstream, original: registry)
    }

    /// Internal rather than private so the version boundary can be tested directly:
    /// it is an off-by-one waiting to happen and the failure it causes — a call an
    /// old registry rejects — is indirect enough to be hard to trace back.
    static func supportsFilters(_ version: [Int]?) -> Bool {
        guard let version else { return false }
        for (theirs, minimum) in zip(version, filtersMinimumVersion) {
            if theirs != minimum { return theirs > minimum }
        }
        return version.count >= filtersMinimumVersion.count
    }
}

extension TelepathURL {
    /// Applies `mergeAhaInfo`'s precedence: local `path` always wins, local `user`
    /// wins when the local URL specified one, upstream wins everything else.
    ///
    /// The order is load-bearing. Getting `user` backwards would authenticate as
    /// whoever AHA suggests instead of whoever the caller named, and AHA fills that
    /// field in from the *requesting* user, so the mistake would look correct in
    /// every single-user test.
    func mergingAHAInfo(_ upstream: [String: MsgpackValue], original: String) throws -> TelepathURL {
        var merged = self

        guard let rawScheme = upstream["scheme"]?.stringValue,
              let scheme = Scheme(rawValue: rawScheme) else {
            throw TelepathError.invalidURL(original, reason: "aha returned no usable scheme")
        }
        guard scheme != .aha else {
            throw TelepathError.invalidURL(original, reason: "aha resolved to another aha:// URL")
        }
        merged.scheme = scheme

        merged.host = upstream["host"]?.stringValue
        if let port = upstream["port"]?.intValue {
            merged.port = Int(port)
        } else {
            merged.port = scheme == .unix || scheme == .cell ? 0 : Self.defaultPort
        }
        if let path = upstream["path"]?.stringValue, scheme == .unix || scheme == .cell {
            merged.path = path
        }

        // Local user wins only if the local URL named one.
        if user == nil { merged.user = upstream["user"]?.stringValue }
        if let password = upstream["passwd"]?.stringValue, self.password == nil {
            merged.password = password
        }

        // TLS parameters come from upstream when the local URL did not set them, so
        // a resolved ssl:// gets §3.7's rules with the registry's pinning intact.
        if certHash == nil { merged.certHash = upstream["certhash"]?.stringValue }
        if certName == nil { merged.certName = upstream["certname"]?.stringValue }
        if hostnameOverride == nil { merged.hostnameOverride = upstream["hostname"]?.stringValue }

        // Local path wins outright, which for us means the share name: mergeAhaInfo
        // discards the upstream path before merging, so nothing is read from it
        // here. Assigning `merged.share = share` would say so more loudly but is a
        // no-op — `merged` is already a copy of self — and a no-op that reads as
        // logic is worse than a comment.
        merged.wantsMirror = false
        return merged
    }
}
