import Msgpack
import NIOCore
import NIOPosix
import TelepathTestKit
import Testing
@testable import Telepath

/// spec.md M7. Every rule here is a reading of `synapse/telepath.py` and
/// `synapse/lib/aha.py` at 2.249.0; these pin the ones inference gets wrong.
@Suite struct AHAResolutionTests {
    private static let session = "0123456789abcdef0123456789abcdef"

    private static func handshakeReply(version: MsgpackValue) -> MsgpackValue {
        .array([
            .string("tele:syn"),
            .map([
                .string("vers"): .array([.uint(3), .uint(0)]),
                .string("retn"): .array([.bool(true), .null]),
                .string("sess"): .string(session),
                .string("sharinfo"): .map([
                    .string("meths"): .map([.string("getAhaSvc"): .map([:])]),
                    .string("syn:version"): version,
                ]),
                .string("features"): .map([.string("tasks"): .uint(1)]),
            ]),
        ])
    }

    /// A registry that answers `getAhaSvc` with whatever the test supplies, and
    /// records the arguments it was called with.
    private actor Registry {
        private(set) var sawFilters: MsgpackValue?
        private(set) var sawName: String?
        private(set) var callCount = 0

        func record(name: String?, filters: MsgpackValue?) {
            callCount += 1
            sawName = name
            sawFilters = filters
        }
    }

    private func withRegistry<T>(
        version: MsgpackValue = .array([.uint(2), .uint(249), .uint(0)]),
        answer: @escaping @Sendable (Registry) -> MsgpackValue,
        _ body: (String, Registry) async throws -> T
    ) async throws -> T {
        let registry = Registry()
        let daemon = try await FakeDaemon.start { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply(version: version))
            case "t2:init":
                let name = message.todoArgs.first?.stringValue
                let filters = message.info["todo"]?[2]?["filters"]
                await registry.record(name: name, filters: filters)
                try await connection.send("t2:fini", [
                    .string("retn"): .array([.bool(true), answer(registry)]),
                ])
            default:
                break
            }
        }
        do {
            let result = try await body(daemon.url, registry)
            await daemon.stop()
            return result
        } catch {
            await daemon.stop()
            throw error
        }
    }

    /// An `svcinfo` pointing at a service that does not have to exist: resolution
    /// is what is under test, not the connection that follows it.
    private static func svcAnswer(
        urlinfo: [MsgpackValue: MsgpackValue],
        online: MsgpackValue = .string("some-iden"),
        extra: [MsgpackValue: MsgpackValue] = [:]
    ) -> MsgpackValue {
        var outer: [MsgpackValue: MsgpackValue] = [
            .string("name"): .string("cortex.synapse"),
            .string("svcinfo"): .map([
                .string("online"): online,
                .string("urlinfo"): .map(urlinfo),
            ]),
        ]
        for (key, value) in extra { outer[key] = value }
        return .map(outer)
    }

    private func resolve(_ url: String, registries: [String]) async throws -> TelepathURL {
        var config = Config()
        config.ahaRegistries = registries
        return try await AHAResolver.resolve(
            TelepathURL(url),
            registries: registries,
            logger: config.logger,
            open: { try await Proxy.open($0, config: Config()) })
    }

    // MARK: - Parsing

    @Test("an aha URL names a service, not a host")
    func parsesServiceName() throws {
        let url = try TelepathURL("aha://cortex.synapse")
        #expect(url.scheme == .aha)
        #expect(url.host == "cortex.synapse")
        // Zero rather than 27492: a half-resolved URL must not be dialable.
        #expect(url.port == 0)
    }

    /// A name ending in `...` is relative and completed by the registry with its own
    /// network. The client sends it as written.
    @Test("a relative service name is passed through untouched")
    func passesRelativeNameThrough() throws {
        let url = try TelepathURL("aha://cortex...")
        #expect(url.host == "cortex...")
    }

    @Test("a mirror request parses, and a typo does not read as false")
    func parsesMirror() throws {
        #expect(try TelepathURL("aha://cortex?mirror=true").wantsMirror)
        #expect(try !TelepathURL("aha://cortex?mirror=false").wantsMirror)
        #expect(try !TelepathURL("aha://cortex").wantsMirror)
        #expect(throws: TelepathError.self) { _ = try TelepathURL("aha://cortex?mirror=ture") }
    }

    /// The transport must never see an unresolved aha URL.
    @Test("connecting to an unresolved aha URL fails rather than dialing")
    func linkRefusesUnresolved() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        await #expect(throws: TelepathError.self) {
            _ = try await Link.connect(to: TelepathURL("aha://cortex"), group: group,
                                       timeout: .seconds(5), certificateDirectory: nil)
        }
        try await group.shutdownGracefully()
    }

    // MARK: - Resolution

    @Test("a service resolves to its registered address")
    func resolvesToAddress() async throws {
        try await withRegistry(answer: { _ in
            Self.svcAnswer(urlinfo: [
                .string("scheme"): .string("tcp"),
                .string("host"): .string("10.0.0.5"),
                .string("port"): .uint(30000),
                .string("user"): .string("ahauser"),
            ])
        }) { registryURL, registry in
            let resolved = try await resolve("aha://cortex.synapse", registries: [registryURL])
            #expect(resolved.scheme == .tcp)
            #expect(resolved.host == "10.0.0.5")
            #expect(resolved.port == 30000)
            #expect(resolved.user == "ahauser")
            #expect(await registry.sawName == "cortex.synapse")
        }
    }

    /// The precedence rule most likely to be got backwards, and the one that would
    /// look correct in every single-user test: AHA fills `user` in from the
    /// *requesting* user, so taking its answer over the caller's would usually
    /// produce the same string.
    @Test("a locally specified user beats the one AHA suggests")
    func localUserWins() async throws {
        try await withRegistry(answer: { _ in
            Self.svcAnswer(urlinfo: [
                .string("scheme"): .string("tcp"),
                .string("host"): .string("10.0.0.5"),
                .string("user"): .string("ahauser"),
            ])
        }) { registryURL, _ in
            let resolved = try await resolve("aha://root@cortex.synapse", registries: [registryURL])
            #expect(resolved.user == "root", "the caller's user must survive resolution")
        }
    }

    /// The other half: with no local user, AHA's suggestion is what authenticates.
    @Test("AHA supplies the user when the caller did not")
    func upstreamUserUsedWhenAbsent() async throws {
        try await withRegistry(answer: { _ in
            Self.svcAnswer(urlinfo: [
                .string("scheme"): .string("tcp"),
                .string("host"): .string("10.0.0.5"),
                .string("user"): .string("ahauser"),
            ])
        }) { registryURL, _ in
            let resolved = try await resolve("aha://cortex.synapse", registries: [registryURL])
            #expect(resolved.user == "ahauser")
        }
    }

    /// Resolution recursing into `ssl://` has to carry the pinning with it, or a
    /// resolved service silently drops to an unverified connection.
    @Test("an ssl service keeps its TLS parameters through the merge")
    func carriesTLSParameters() async throws {
        try await withRegistry(answer: { _ in
            Self.svcAnswer(urlinfo: [
                .string("scheme"): .string("ssl"),
                .string("host"): .string("cortex.aha"),
                .string("certhash"): .string("abc123"),
                .string("hostname"): .string("cortex.aha"),
            ])
        }) { registryURL, _ in
            let resolved = try await resolve("aha://cortex.synapse", registries: [registryURL])
            #expect(resolved.scheme == .ssl)
            #expect(resolved.certHash == "abc123")
            #expect(resolved.hostnameOverride == "cortex.aha")
            #expect(resolved.port == TelepathURL.defaultPort)
        }
    }

    /// `mergeAhaInfo` discards the upstream path outright before merging, and for
    /// this client the share name is what that path carries.
    @Test("the local share survives resolution")
    func localShareWins() async throws {
        try await withRegistry(answer: { _ in
            Self.svcAnswer(urlinfo: [
                .string("scheme"): .string("tcp"),
                .string("host"): .string("10.0.0.5"),
                .string("path"): .string("someothershare"),
            ])
        }) { registryURL, _ in
            let resolved = try await resolve("aha://cortex.synapse/myshare", registries: [registryURL])
            #expect(resolved.share == "myshare")
        }
    }

    // MARK: - Filters and versions

    @Test("a modern registry is asked to filter")
    func sendsFiltersToModernRegistry() async throws {
        try await withRegistry(answer: { _ in
            Self.svcAnswer(urlinfo: [
                .string("scheme"): .string("tcp"), .string("host"): .string("10.0.0.5"),
            ])
        }) { registryURL, registry in
            _ = try await resolve("aha://cortex?mirror=true", registries: [registryURL])
            let filters = await registry.sawFilters
            #expect(filters?["mirror"] == .bool(true))
        }
    }

    /// Sending `filters` to a pre-2.95.0 registry fails the call outright, so it is
    /// omitted — the argument did not exist yet.
    @Test("an old registry is not sent an argument it predates")
    func omitsFiltersForOldRegistry() async throws {
        try await withRegistry(version: .array([.uint(2), .uint(94), .uint(0)]), answer: { _ in
            Self.svcAnswer(urlinfo: [
                .string("scheme"): .string("tcp"), .string("host"): .string("10.0.0.5"),
            ])
        }) { registryURL, registry in
            _ = try await resolve("aha://cortex", registries: [registryURL])
            #expect(await registry.sawFilters == nil)
        }
    }

    /// Asking for a mirror from a registry that cannot filter must fail rather than
    /// silently hand back the leader.
    @Test("a mirror request an old registry cannot serve fails loudly")
    func mirrorOnOldRegistryFails() async throws {
        try await withRegistry(version: .array([.uint(2), .uint(94), .uint(0)]), answer: { _ in
            Self.svcAnswer(urlinfo: [
                .string("scheme"): .string("tcp"), .string("host"): .string("10.0.0.5"),
            ])
        }) { registryURL, _ in
            do {
                _ = try await resolve("aha://cortex?mirror=true", registries: [registryURL])
                Issue.record("expected the mirror request to fail")
            } catch let error as TelepathError {
                guard case .ahaMirrorUnsupported = error else {
                    Issue.record("wrong error: \(error)")
                    return
                }
            }
        }
    }

    @Test("2.95.0 exactly is new enough")
    func versionBoundaryIsInclusive() {
        #expect(AHAResolver.supportsFilters([2, 95, 0]))
        #expect(!AHAResolver.supportsFilters([2, 94, 9]))
        #expect(AHAResolver.supportsFilters([3, 0, 0]))
        #expect(!AHAResolver.supportsFilters(nil))
    }

    // MARK: - Failure modes, which M7 requires be distinct

    @Test("no registries configured is its own error")
    func noRegistriesConfigured() async throws {
        do {
            _ = try await resolve("aha://cortex", registries: [])
            Issue.record("expected a failure")
        } catch let error as TelepathError {
            guard case .ahaNoRegistries(let service) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(service == "cortex")
        }
    }

    /// A registry that has never heard of the service returns None. Falling through
    /// every registry is a failure, not an empty success.
    @Test("an unknown service fails rather than resolving to nothing")
    func unknownService() async throws {
        try await withRegistry(answer: { _ in .null }) { registryURL, _ in
            do {
                _ = try await resolve("aha://nosuch", registries: [registryURL])
                Issue.record("expected a failure")
            } catch let error as TelepathError {
                guard case .ahaLookupFailed = error else {
                    Issue.record("wrong error: \(error)")
                    return
                }
            }
        }
    }

    /// Registered but not currently up. Python skips to the next registry rather
    /// than returning an address nothing is listening on.
    @Test("an offline service is skipped, not returned")
    func offlineService() async throws {
        try await withRegistry(answer: { _ in
            Self.svcAnswer(
                urlinfo: [.string("scheme"): .string("tcp"), .string("host"): .string("10.0.0.5")],
                online: .null)
        }) { registryURL, _ in
            await #expect(throws: TelepathError.self) {
                _ = try await resolve("aha://cortex", registries: [registryURL])
            }
        }
    }

    /// An unreachable registry must not end the search; the next one may answer.
    @Test("an unreachable registry falls through to the next")
    func unreachableRegistryFallsThrough() async throws {
        try await withRegistry(answer: { _ in
            Self.svcAnswer(urlinfo: [
                .string("scheme"): .string("tcp"), .string("host"): .string("10.0.0.5"),
            ])
        }) { good, _ in
            let dead = "unix:///tmp/telepath-no-such-registry-\(UInt32.random(in: 0..<UInt32.max)).sock"
            let resolved = try await resolve("aha://cortex", registries: [dead, good])
            #expect(resolved.host == "10.0.0.5")
        }
    }

    /// Every registry unreachable reports the last transport failure, not
    /// "unknown service" — the two want different fixes from whoever reads it.
    @Test("all registries unreachable reports the connection failure")
    func allRegistriesUnreachable() async throws {
        let dead = "unix:///tmp/telepath-no-such-registry-\(UInt32.random(in: 0..<UInt32.max)).sock"
        do {
            _ = try await resolve("aha://cortex", registries: [dead])
            Issue.record("expected a failure")
        } catch let error as TelepathError {
            if case .ahaLookupFailed = error {
                Issue.record("reported an unknown service when the registry was unreachable")
            }
        } catch {
            // A transport error from the registry connection is the right answer.
        }
    }

    /// Pools are M8. Connecting to one member would silently ignore the rest, so
    /// this refuses instead — and refuses without trying other registries, since a
    /// pool is a definite answer about the name.
    @Test("a pool is refused rather than treated as a service")
    func poolIsRefused() async throws {
        try await withRegistry(answer: { _ in
            Self.svcAnswer(
                urlinfo: [.string("scheme"): .string("tcp"), .string("host"): .string("10.0.0.5")],
                extra: [.string("services"): .array([.string("a"), .string("b")])])
        }) { registryURL, _ in
            do {
                _ = try await resolve("aha://pool", registries: [registryURL])
                Issue.record("expected the pool to be refused")
            } catch let error as TelepathError {
                guard case .ahaPoolNotSupported(let name) = error else {
                    Issue.record("wrong error: \(error)")
                    return
                }
                #expect(name == "cortex.synapse")
            }
        }
    }

    /// The whole path, rather than the resolver in isolation: `Proxy.open` on an
    /// `aha://` URL must resolve, then connect to what it resolved to, and end up
    /// with a working session against the service rather than the registry.
    @Test("Proxy.open resolves an aha URL and connects to the service", .timeLimit(.minutes(1)))
    func openResolvesAndConnects() async throws {
        // The service the registry will point at.
        let service = try await FakeDaemon.start { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply(
                    version: .array([.uint(2), .uint(249), .uint(0)])))
            case "t2:init":
                try await connection.send("t2:fini", [
                    .string("retn"): .array([.bool(true), .string("the service")]),
                ])
            default:
                break
            }
        }
        let servicePath = String(service.url.dropFirst("unix://".count))

        try await withRegistry(answer: { _ in
            Self.svcAnswer(urlinfo: [
                .string("scheme"): .string("unix"),
                .string("path"): .string(servicePath),
            ])
        }) { registryURL, registry in
            var config = Config()
            config.ahaRegistries = [registryURL]
            let proxy = try await Proxy.open("aha://cortex.synapse", config: config)
            let value = try await proxy.call("anything")
            #expect(value.stringValue == "the service",
                    "the call reached the registry instead of the service")
            #expect(await registry.callCount == 1)
            await proxy.close()
        }
        await service.stop()
    }

    /// A registry list that points at itself would otherwise recurse forever.
    @Test("an aha registry URL is rejected")
    func ahaRegistryRejected() async throws {
        await #expect(throws: TelepathError.self) {
            _ = try await resolve("aha://cortex", registries: ["aha://registry"])
        }
    }
}
