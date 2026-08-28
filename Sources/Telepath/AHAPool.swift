import Logging
import Msgpack

/// A client for an AHA *pool*: a name that resolves to a changing set of services
/// rather than one, per spec §3.9.
///
/// A pool is deliberately not a ``Proxy``. A `Proxy` owns one authenticated session
/// on one server, and everything built on it — the link pool, shares, `state` —
/// means "this session". A pool has no single session: each member holds its own,
/// and membership changes underneath the caller. Presenting it as a `Proxy` would
/// make `sessionIden` and `state` lie.
///
/// Calls round-robin over the members that are currently up. Membership is learned
/// from a long-lived topology generator on the registry, which first replays the
/// current members and then streams changes.
public actor AHAPool {
    /// Every AHA pool topology message this client understands.
    enum TopologyMessage {
        case add(name: String)
        case remove(name: String)
        /// Anything else. Vertex adds message kinds between minor releases, and
        /// §3.4's rule for the main link applies here for the same reason: an
        /// unrecognised kind is not a protocol error.
        case unrecognised(name: String)

        init(_ value: MsgpackValue) {
            guard let items = value.arrayValue, items.count == 2,
                  let kind = items[0].stringValue else {
                self = .unrecognised(name: "malformed")
                return
            }
            switch kind {
            case "svc:add":
                // The member is connected by re-resolving `aha://<name>`, not from
                // the urlinfo carried here. Python does the same, and it is the
                // behaviour that survives a member moving between the topology
                // message and the connection attempt.
                guard let name = items[1]["name"]?.stringValue else {
                    self = .unrecognised(name: kind)
                    return
                }
                self = .add(name: name)
            case "svc:del":
                guard let name = items[1]["name"]?.stringValue else {
                    self = .unrecognised(name: kind)
                    return
                }
                self = .remove(name: name)
            default:
                self = .unrecognised(name: kind)
            }
        }
    }

    public let name: String
    private let config: Config
    private var members: [String: Proxy] = [:]
    /// Round-robin order. Refilled from `members` when it empties, matching
    /// Python's deque.
    private var rotation: [String] = []
    private var topologyTask: Task<Void, Never>?
    /// One watcher per member, evicting it when its session ends.
    private var memberWatchers: [String: Task<Void, Never>] = [:]
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init(name: String, config: Config) {
        self.name = name
        self.config = config
    }

    /// Opens a pool by its AHA name, e.g. `aha://cortex-pool...`.
    ///
    /// Returns as soon as the topology stream is running; the first call waits for
    /// a member to come up. Opening does not fail because the pool is momentarily
    /// empty — that is a normal state during a rolling restart, not a setup error.
    public static func open(_ url: String, config: Config = Config()) async throws -> AHAPool {
        try await open(TelepathURL(url), config: config)
    }

    public static func open(_ url: TelepathURL, config: Config = Config()) async throws -> AHAPool {
        guard url.scheme == .aha, let name = url.host else {
            throw TelepathError.invalidURL("\(url)", reason: "a pool requires an aha:// URL")
        }
        guard !config.ahaRegistries.isEmpty else {
            throw TelepathError.ahaNoRegistries(service: name)
        }
        // Confirm the name really is a pool before spinning up a topology task.
        // Resolution succeeding means it is a single service, and a pool client
        // that quietly followed an empty topology forever would be indisting-
        // uishable from one whose members are all down.
        do {
            _ = try await AHAResolver.resolve(
                url,
                registries: config.ahaRegistries,
                logger: config.logger,
                open: { registry in
                    var registryConfig = config
                    registryConfig.ahaRegistries = []
                    return try await Proxy.open(registry, config: registryConfig)
                })
            throw TelepathError.ahaIsNotAPool(name: name)
        } catch let error as TelepathError {
            guard case .ahaIsAPool = error else { throw error }
        }

        let pool = AHAPool(name: name, config: config)
        await pool.startTopologySync()
        return pool
    }

    /// Issues a call on one member.
    ///
    /// Waits for a member to be available rather than failing an empty pool, up to
    /// `Config.callTimeout` when one is set.
    public func call(
        _ method: String,
        _ args: [MsgpackValue] = [],
        kwargs: [String: MsgpackValue] = [:],
        share: String? = nil
    ) async throws -> MsgpackValue {
        let member = try await nextMember()
        return try await member.call(method, args, kwargs: kwargs, share: share)
    }

    /// A generator call on one member.
    ///
    /// The whole stream stays on the member it started on: a generator owns its
    /// link until the terminator (§3.3), and moving mid-stream would lose the
    /// server-side cursor.
    public func stream(
        _ method: String,
        _ args: [MsgpackValue] = [],
        kwargs: [String: MsgpackValue] = [:],
        share: String? = nil
    ) async throws -> TelepathStream {
        let member = try await nextMember()
        return member.stream(method, args, kwargs: kwargs, share: share)
    }

    /// The names of the members currently up, for tests and diagnostics.
    public var memberNames: [String] { members.keys.sorted() }

    public func close() async {
        guard !closed else { return }
        closed = true
        topologyTask?.cancel()
        await topologyTask?.value
        topologyTask = nil
        await shutDownMembers()
        // Anything waiting for a member will never get one now.
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    // MARK: - Membership

    private func nextMember() async throws -> Proxy {
        // Nil means wait indefinitely, which is the default and is what a rolling
        // restart wants. `callTimeout` bounds one wait, matching Python's
        // `wait_for(getNextProxy(), timeout)`.
        let deadline = config.callTimeout.map { ContinuousClock.now + $0 }

        while true {
            guard !closed else { throw TelepathError.proxyClosed }

            // Two passes: drain whatever the rotation holds, then refill from live
            // membership and drain again. One pass was not enough — a rotation
            // holding only names that have since been removed would fall through to
            // the wait while healthy members sat idle, until the next topology
            // message happened to wake it.
            for _ in 0..<2 {
                while let candidate = rotation.first {
                    rotation.removeFirst()
                    if let member = members[candidate] { return member }
                }
                if members.isEmpty { break }
                rotation = members.keys.sorted()
            }

            guard !closed else { throw TelepathError.proxyClosed }
            if let deadline, ContinuousClock.now >= deadline {
                throw TelepathError.timedOut("waiting for an available pool member")
            }
            try await waitForMember(until: deadline)
        }
    }

    /// Suspends until membership changes, or until `deadline`.
    ///
    /// Cancellation-aware, because a caller waiting on an empty pool is exactly the
    /// case where a task deadline or a cancelled parent has to be honoured. The
    /// deadline needs its own waker: nothing else will arrive to wake a caller
    /// waiting on a pool that stays empty.
    private func waitForMember(until deadline: ContinuousClock.Instant?) async throws {
        let waker: Task<Void, Never>? = deadline.map { deadline in
            Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self?.wakeWaiters()
            }
        }
        defer { waker?.cancel() }

        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.wakeWaiters() }
        }
    }

    private func wakeWaiters() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    private func add(_ memberName: String) async {
        guard !closed else { return }
        // A repeated add replaces the existing connection rather than duplicating
        // it: the registry is telling us the member changed.
        if let existing = members.removeValue(forKey: memberName) {
            await existing.close()
        }
        var memberConfig = config
        memberConfig.ahaRegistries = config.ahaRegistries
        do {
            let proxy = try await Proxy.open("aha://\(memberName)", config: memberConfig)
            guard !closed else {
                await proxy.close()
                return
            }
            members[memberName] = proxy
            watchForDeath(of: memberName, proxy)
            wakeWaiters()
        } catch {
            // One member failing to come up is not a pool failure. The registry
            // will say so again if it matters, and the other members still serve.
            // Drop the name from the rotation too, or a caller drains a rotation
            // entry that can never resolve.
            rotation.removeAll { $0 == memberName }
            config.logger.warning("aha pool \(name): member \(memberName) did not connect: \(error)")
        }
    }

    /// Evicts a member whose session ends.
    ///
    /// `Proxy` never re-handshakes, by design, so a member whose link drops stays
    /// dead. Without this the pool keeps it in the rotation and every call landing
    /// on it fails — a partition AHA cannot see would permanently poison 1/N of all
    /// traffic. §3.9 says calls round-robin over the *ready* members, and this is
    /// what makes "ready" true. Python gets the same property from its per-member
    /// reconnecting client.
    private func watchForDeath(of memberName: String, _ proxy: Proxy) {
        memberWatchers[memberName]?.cancel()
        memberWatchers[memberName] = Task { [weak self] in
            for await state in proxy.state {
                guard case .disconnected = state else { continue }
                await self?.memberDied(memberName, proxy)
                return
            }
        }
    }

    private func memberDied(_ memberName: String, _ proxy: Proxy) async {
        // Only if it is still the same connection: a re-add may have replaced it,
        // and evicting by name alone would drop the healthy replacement.
        guard let current = members[memberName], current === proxy else { return }
        members.removeValue(forKey: memberName)
        rotation.removeAll { $0 == memberName }
        memberWatchers.removeValue(forKey: memberName)?.cancel()
        config.logger.info("aha pool \(name): member \(memberName) dropped out")
        await proxy.close()
    }

    private func remove(_ memberName: String) async {
        memberWatchers.removeValue(forKey: memberName)?.cancel()
        guard let proxy = members.removeValue(forKey: memberName) else { return }
        rotation.removeAll { $0 == memberName }
        await proxy.close()
    }

    /// Nothing may outlive the members it watches, so watchers are cancelled and
    /// awaited before the proxies they hold are closed.
    private func shutDownMembers() async {
        let watchers = memberWatchers
        memberWatchers.removeAll()
        for (_, watcher) in watchers { watcher.cancel() }
        for (_, watcher) in watchers { await watcher.value }

        let current = members
        members.removeAll()
        rotation.removeAll()
        for (_, proxy) in current { await proxy.close() }
    }

    // MARK: - Topology

    private func startTopologySync() {
        topologyTask = Task { [weak self] in
            guard let self else { return }
            await self.syncTopology()
        }
    }

    /// Follows the registry's topology stream, rebuilding from scratch whenever it
    /// drops.
    ///
    /// Rebuilding rather than patching is Python's behaviour and the only correct
    /// one: while the stream was down, membership could have changed in ways no
    /// message will now describe, so the current set is unknowable rather than
    /// merely stale.
    private func syncTopology() async {
        while !closed && !Task.isCancelled {
            do {
                try await followTopology()
            } catch {
                guard !closed && !Task.isCancelled else { return }
                config.logger.warning("aha pool \(name): topology stream restarting: \(error)")
            }
            guard !closed && !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func followTopology() async throws {
        var lastError: (any Error)?
        for registry in config.ahaRegistries {
            do {
                var registryConfig = config
                registryConfig.ahaRegistries = []
                // The topology stream is a long-lived generator, so its link is
                // owned for the life of the stream and never returned to the pool
                // (§3.3). Its own registry connection is closed when it ends.
                let proxy = try await Proxy.open(registry, config: registryConfig)

                // Reset here, once a registry is actually reachable and before its
                // replay begins — the placement Python uses in `_toposync`.
                //
                // Resetting only after *every* registry failed was wrong in a way a
                // single-registry test cannot show: a stream error falls through to
                // the next registry, and that registry's replay would merge onto
                // membership describing a moment that has passed, leaving the pool
                // dispatching to a member the new registry never mentioned.
                //
                // Doing it after the connect rather than before also means an
                // unreachable registry does not empty a pool that is serving fine.
                await shutDownMembers()

                do {
                    try await consume(proxy.stream("iterPoolTopo", [.string(name)]))
                    await proxy.close()
                    return
                } catch {
                    await proxy.close()
                    throw error
                }
            } catch {
                lastError = error
                config.logger.debug("aha pool \(name): registry \(registry) unusable: \(error)")
            }
        }
        throw lastError ?? TelepathError.ahaLookupFailed(service: name)
    }

    private func consume(_ stream: TelepathStream) async throws {
        for try await message in stream {
            guard !closed && !Task.isCancelled else { return }
            switch TopologyMessage(message) {
            case .add(let memberName):
                await add(memberName)
            case .remove(let memberName):
                await remove(memberName)
            case .unrecognised(let kind):
                config.logger.info("aha pool \(name): ignoring topology message \(kind)")
            }
        }
    }
}
