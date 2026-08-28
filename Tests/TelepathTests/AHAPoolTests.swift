import Msgpack
import TelepathTestKit
import Testing
@testable import Telepath

/// spec.md M8. A pool URL enters pool mode, replays membership, round-robins
/// calls, honours `svc:add` and `svc:del` live, resets on a dropped topology
/// stream, and drops topology messages it does not recognise.
@Suite struct AHAPoolTests {
    private static let session = "0123456789abcdef0123456789abcdef"

    private static func handshakeReply(methods: [String]) -> MsgpackValue {
        var meths: [MsgpackValue: MsgpackValue] = [:]
        for method in methods {
            meths[.string(method)] = method == "iterPoolTopo"
                ? .map([.string("genr"): .bool(true)])
                : .map([:])
        }
        return .array([
            .string("tele:syn"),
            .map([
                .string("vers"): .array([.uint(3), .uint(0)]),
                .string("retn"): .array([.bool(true), .null]),
                .string("sess"): .string(session),
                .string("sharinfo"): .map([
                    .string("meths"): .map(meths),
                    .string("syn:version"): .array([.uint(2), .uint(249), .uint(0)]),
                ]),
                .string("features"): .map([.string("tasks"): .uint(1)]),
            ]),
        ])
    }

    /// A member service that reports which one it is, so round-robin is observable.
    private static func makeMember(named identity: String) async throws -> FakeDaemon {
        try await FakeDaemon.start { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(handshakeReply(methods: ["whoami"]))
            case "t2:init":
                try await connection.send("t2:fini", [
                    .string("retn"): .array([.bool(true), .string(identity)]),
                ])
            default:
                break
            }
        }
    }

    /// Drives one registry: it answers `getAhaSvc` (pool or service) and serves the
    /// topology generator from a script the test controls.
    private actor Script {
        /// Topology messages still to send, in order.
        private var pending: [MsgpackValue] = []
        /// Whether the current topology stream should end after draining `pending`.
        ///
        /// Default false, because a real `iterPoolTopo` **stays open indefinitely**
        /// after replaying membership — verified against a live AHA. An earlier
        /// version of this fake ended the stream every time, which made the pool
        /// tear down and rebuild on a one-second cycle. The tests passed, and they
        /// were watching constant churn rather than the steady state.
        private var endsAfterDraining = false
        private(set) var topoCalls = 0
        /// Member name to unix socket path, for resolving `aha://<name>`.
        var addresses: [String: String] = [:]

        /// What the *next* stream replays, once the current one has been dropped.
        private var queuedForNextStream: [MsgpackValue]?

        init(pending: [MsgpackValue] = []) {
            self.pending = pending
        }

        func beginStream() -> ([MsgpackValue], Bool) {
            if let queued = queuedForNextStream {
                pending = queued
                queuedForNextStream = nil
                endsAfterDraining = false
            }
            let items = pending
            pending = []
            topoCalls += 1
            return (items, endsAfterDraining)
        }

        /// Queues messages for the stream that is currently open.
        func send(_ items: [MsgpackValue]) { pending.append(contentsOf: items) }

        /// Drops the live stream, and says what the replacement replays.
        ///
        /// One call rather than two so the test cannot race the pool's retry: the
        /// replacement's contents are set before the drop is visible.
        func dropStream(thenReplay items: [MsgpackValue]) {
            queuedForNextStream = items
            endsAfterDraining = true
        }

        /// Whether the stream should *fail* rather than end cleanly. A clean end
        /// and an error take different paths through the client, and only the
        /// error path falls through to the next registry.
        private(set) var failsAfterDraining = false
        func setFailsAfterDraining(_ value: Bool) { failsAfterDraining = value }

        func drainPending() -> [MsgpackValue] {
            let items = pending
            pending = []
            return items
        }
        var shouldEnd: Bool { endsAfterDraining }
        func setAddress(_ name: String, _ path: String) { addresses[name] = path }
    }

    private static func add(_ name: String) -> MsgpackValue {
        .array([.string("svc:add"), .map([.string("name"): .string(name)])])
    }

    private static func remove(_ name: String) -> MsgpackValue {
        .array([.string("svc:del"), .map([.string("name"): .string(name)])])
    }

    /// A registry serving `poolName` as a pool, resolving members by name, and
    /// replaying `script`'s topology messages.
    private func withRegistry<T>(
        poolName: String,
        script: Script,
        _ body: (String) async throws -> T
    ) async throws -> T {
        let daemon = try await FakeDaemon.start { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(
                    Self.handshakeReply(methods: ["getAhaSvc", "iterPoolTopo"]))

            case "t2:init":
                let method = message.todoMethod ?? ""
                let requested = message.todoArgs.first?.stringValue ?? ""

                if method == "getAhaSvc" {
                    if requested == poolName {
                        try await connection.send("t2:fini", [
                            .string("retn"): .array([.bool(true), .map([
                                .string("name"): .string(poolName),
                                .string("services"): .array([]),
                                .string("svcinfo"): .map([
                                    .string("online"): .string("iden"),
                                    .string("urlinfo"): .map([:]),
                                ]),
                            ])]),
                        ])
                        return
                    }
                    guard let path = await script.addresses[requested] else {
                        try await connection.send("t2:fini", [
                            .string("retn"): .array([.bool(true), .null]),
                        ])
                        return
                    }
                    try await connection.send("t2:fini", [
                        .string("retn"): .array([.bool(true), .map([
                            .string("name"): .string(requested),
                            .string("svcinfo"): .map([
                                .string("online"): .string("iden"),
                                .string("urlinfo"): .map([
                                    .string("scheme"): .string("unix"),
                                    .string("path"): .string(path),
                                ]),
                            ]),
                        ])]),
                    ])
                    return
                }

                if method == "iterPoolTopo" {
                    // A generator is announced before it yields; without this the
                    // client treats the first yield as a protocol violation.
                    try await connection.send("t2:genr", [:])
                    var (items, ends) = await script.beginStream()
                    while true {
                        for item in items {
                            try await connection.send("t2:yield", [.string("retn"): .array([
                                .bool(true), item,
                            ])])
                        }
                        let fails = await script.failsAfterDraining
                        if ends || fails { break }
                        // Stay open the way a real registry does, picking up
                        // anything the test queues while the stream is live.
                        try await Task.sleep(for: .milliseconds(20))
                        items = await script.drainPending()
                        ends = await script.shouldEnd
                    }
                    if await script.failsAfterDraining {
                        // An error mid-generator, which is what a registry going
                        // away actually looks like.
                        try await connection.send("t2:yield", [.string("retn"): .array([
                            .bool(false),
                            .array([.string("IsFini"), .map([
                                .string("mesg"): .string("registry went away"),
                            ])]),
                        ])])
                        return
                    }
                    // A generator terminates with retn: None.
                    try await connection.send("t2:yield", [.string("retn"): .null])
                    return
                }

            default:
                break
            }
        }
        do {
            let result = try await body(daemon.url)
            await daemon.stop()
            return result
        } catch {
            await daemon.stop()
            throw error
        }
    }

    private func config(_ registry: String) -> Config {
        var config = Config()
        config.ahaRegistries = [registry]
        return config
    }

    /// Waits for membership to settle rather than sleeping a fixed interval, which
    /// is the difference between a test and a flake.
    private func waitForMembers(_ pool: AHAPool, count: Int) async throws {
        for _ in 0..<200 {
            if await pool.memberNames.count == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("pool never reached \(count) members; saw \(await pool.memberNames)")
    }

    // MARK: - Entering pool mode

    /// A pool has no single session, so `Proxy` refuses it and says where to go.
    @Test("Proxy.open refuses a pool", .timeLimit(.minutes(1)))
    func proxyRefusesAPool() async throws {
        let script = Script(pending: [])
        try await withRegistry(poolName: "mypool", script: script) { registry in
            do {
                _ = try await Proxy.open("aha://mypool", config: config(registry))
                Issue.record("expected Proxy.open to refuse a pool")
            } catch let error as TelepathError {
                guard case .ahaIsAPool(let name) = error else {
                    Issue.record("wrong error: \(error)")
                    return
                }
                #expect(name == "mypool")
            }
        }
    }

    /// And the symmetry: a pool client opened on a single service is a mistake
    /// worth reporting rather than an empty pool that never fills.
    @Test("AHAPool refuses a single service", .timeLimit(.minutes(1)))
    func poolRefusesAService() async throws {
        let script = Script(pending: [])
        await script.setAddress("plain", "/tmp/does-not-matter.sock")
        try await withRegistry(poolName: "mypool", script: script) { registry in
            do {
                _ = try await AHAPool.open("aha://plain", config: config(registry))
                Issue.record("expected AHAPool.open to refuse a single service")
            } catch let error as TelepathError {
                guard case .ahaIsNotAPool = error else {
                    Issue.record("wrong error: \(error)")
                    return
                }
            }
        }
    }

    @Test("a pool with no registries configured fails at open")
    func poolNeedsRegistries() async throws {
        await #expect(throws: TelepathError.self) {
            _ = try await AHAPool.open("aha://mypool", config: Config())
        }
    }

    // MARK: - Membership and dispatch

    /// The generator replays current membership before streaming changes, so a pool
    /// opened against a running system is populated without waiting for a change.
    @Test("the topology replay populates the pool", .timeLimit(.minutes(1)))
    func replaysMembership() async throws {
        let alpha = try await Self.makeMember(named: "alpha")
        let beta = try await Self.makeMember(named: "beta")
        let script = Script(pending: [Self.add("alpha"), Self.add("beta")])
        await script.setAddress("alpha", String(alpha.url.dropFirst("unix://".count)))
        await script.setAddress("beta", String(beta.url.dropFirst("unix://".count)))

        try await withRegistry(poolName: "mypool", script: script) { registry in
            let pool = try await AHAPool.open("aha://mypool", config: config(registry))
            try await waitForMembers(pool, count: 2)
            #expect(await pool.memberNames == ["alpha", "beta"])
            await pool.close()
        }
        await alpha.stop()
        await beta.stop()
    }

    @Test("calls round-robin over the members", .timeLimit(.minutes(1)))
    func roundRobins() async throws {
        let alpha = try await Self.makeMember(named: "alpha")
        let beta = try await Self.makeMember(named: "beta")
        let script = Script(pending: [Self.add("alpha"), Self.add("beta")])
        await script.setAddress("alpha", String(alpha.url.dropFirst("unix://".count)))
        await script.setAddress("beta", String(beta.url.dropFirst("unix://".count)))

        try await withRegistry(poolName: "mypool", script: script) { registry in
            let pool = try await AHAPool.open("aha://mypool", config: config(registry))
            try await waitForMembers(pool, count: 2)

            var seen: [String] = []
            for _ in 0..<4 {
                seen.append(try await pool.call("whoami").stringValue ?? "?")
            }
            #expect(Set(seen) == ["alpha", "beta"], "calls did not spread over both members")
            #expect(seen[0] != seen[1], "two consecutive calls hit the same member")
            await pool.close()
        }
        await alpha.stop()
        await beta.stop()
    }

    /// `svc:del` has to take effect immediately: a removed member is usually one
    /// being taken down, and continuing to dispatch to it is what the message
    /// exists to prevent.
    @Test("svc:del removes a member from the rotation", .timeLimit(.minutes(1)))
    func removalTakesEffect() async throws {
        let alpha = try await Self.makeMember(named: "alpha")
        let beta = try await Self.makeMember(named: "beta")
        let script = Script(pending: [
            Self.add("alpha"), Self.add("beta"), Self.remove("beta"),
        ])
        await script.setAddress("alpha", String(alpha.url.dropFirst("unix://".count)))
        await script.setAddress("beta", String(beta.url.dropFirst("unix://".count)))

        try await withRegistry(poolName: "mypool", script: script) { registry in
            let pool = try await AHAPool.open("aha://mypool", config: config(registry))
            try await waitForMembers(pool, count: 1)
            #expect(await pool.memberNames == ["alpha"])

            for _ in 0..<3 {
                #expect(try await pool.call("whoami").stringValue == "alpha")
            }
            await pool.close()
        }
        await alpha.stop()
        await beta.stop()
    }

    /// Vertex adds topology message kinds between minor releases. An unrecognised
    /// one is dropped, exactly as §3.4 requires on the main link — and crucially
    /// the messages after it still arrive.
    @Test("an unknown topology message is dropped, not fatal", .timeLimit(.minutes(1)))
    func unknownTopologyMessageIsDropped() async throws {
        let alpha = try await Self.makeMember(named: "alpha")
        let script = Script(pending: [
            .array([.string("svc:whatever"), .map([.string("name"): .string("future")])]),
            .string("not even a tuple"),
            Self.add("alpha"),
        ])
        await script.setAddress("alpha", String(alpha.url.dropFirst("unix://".count)))

        try await withRegistry(poolName: "mypool", script: script) { registry in
            let pool = try await AHAPool.open("aha://mypool", config: config(registry))
            try await waitForMembers(pool, count: 1)
            #expect(await pool.memberNames == ["alpha"],
                    "an unknown message stopped the messages after it")
            await pool.close()
        }
        await alpha.stop()
    }

    /// A member that will not connect is not a pool failure: the rest still serve.
    ///
    /// The good member comes *first* deliberately. With the failure first, a
    /// mutation that tore the whole pool down on a member error still passed —
    /// there was nothing to tear down yet, and the good member arrived afterwards.
    @Test("a member that cannot be reached does not break the pool", .timeLimit(.minutes(1)))
    func unreachableMemberIsSkipped() async throws {
        let alpha = try await Self.makeMember(named: "alpha")
        let script = Script(pending: [Self.add("alpha"), Self.add("ghost")])
        await script.setAddress("alpha", String(alpha.url.dropFirst("unix://".count)))
        await script.setAddress("ghost", "/tmp/telepath-no-such-member.sock")

        try await withRegistry(poolName: "mypool", script: script) { registry in
            let pool = try await AHAPool.open("aha://mypool", config: config(registry))
            try await waitForMembers(pool, count: 1)
            #expect(try await pool.call("whoami").stringValue == "alpha")
            await pool.close()
        }
        await alpha.stop()
    }

    // MARK: - Reset

    /// The behaviour that cannot be patched: while the topology stream was down,
    /// membership could have changed in ways no message will now describe, so the
    /// current set is unknowable rather than merely stale. Python rebuilds from
    /// scratch and so does this.
    @Test("a dropped topology stream rebuilds the pool", .timeLimit(.minutes(2)))
    func droppedTopologyRebuilds() async throws {
        let alpha = try await Self.makeMember(named: "alpha")
        let beta = try await Self.makeMember(named: "beta")
        let alphaPath = String(alpha.url.dropFirst("unix://".count))
        let betaPath = String(beta.url.dropFirst("unix://".count))

        let script = Script(pending: [Self.add("alpha")])
        await script.setAddress("alpha", alphaPath)
        await script.setAddress("beta", betaPath)

        try await withRegistry(poolName: "mypool", script: script) { registry in
            let pool = try await AHAPool.open("aha://mypool", config: config(registry))
            try await waitForMembers(pool, count: 1)
            #expect(await pool.memberNames == ["alpha"])

            // Drop the stream, and say what its replacement will describe.
            await script.dropStream(thenReplay: [Self.add("beta")])

            // The rebuild drops everything first, so the pool passes through empty
            // and comes back with only what the new stream describes.
            for _ in 0..<400 {
                if await pool.memberNames == ["beta"] { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await pool.memberNames == ["beta"],
                    "the pool patched membership instead of rebuilding it")
            #expect(await script.topoCalls >= 2, "the topology stream was not re-established")
            await pool.close()
        }
        await alpha.stop()
        await beta.stop()
    }

    /// Failing over between registries must reset membership first.
    ///
    /// A stream *error* takes a different path through the client than a clean
    /// end: the error falls through to the next registry, and without a reset the
    /// next registry's replay merges on top of stale membership. The pool then
    /// keeps dispatching to a member the new registry never mentioned — which,
    /// since it was removed while the stream was down, no longer exists.
    @Test("failing over to another registry rebuilds rather than merges",
          .timeLimit(.minutes(2)))
    func failoverBetweenRegistriesRebuilds() async throws {
        let alpha = try await Self.makeMember(named: "alpha")
        let beta = try await Self.makeMember(named: "beta")
        let alphaPath = String(alpha.url.dropFirst("unix://".count))
        let betaPath = String(beta.url.dropFirst("unix://".count))

        // Registry A knows only alpha, and its stream fails.
        let scriptA = Script(pending: [Self.add("alpha")])
        await scriptA.setAddress("alpha", alphaPath)
        await scriptA.setAddress("beta", betaPath)
        // Registry B knows only beta, and stays open.
        let scriptB = Script(pending: [Self.add("beta")])
        await scriptB.setAddress("alpha", alphaPath)
        await scriptB.setAddress("beta", betaPath)

        try await withRegistry(poolName: "mypool", script: scriptA) { registryA in
            try await withRegistry(poolName: "mypool", script: scriptB) { registryB in
                var config = Config()
                config.ahaRegistries = [registryA, registryB]
                let pool = try await AHAPool.open("aha://mypool", config: config)
                try await waitForMembers(pool, count: 1)
                #expect(await pool.memberNames == ["alpha"])

                // Registry A's stream dies. B takes over and describes only beta.
                await scriptA.setFailsAfterDraining(true)

                for _ in 0..<400 {
                    if await pool.memberNames == ["beta"] { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(await pool.memberNames == ["beta"],
                        "failover merged onto stale membership instead of rebuilding")
                await pool.close()
            }
        }
        await alpha.stop()
        await beta.stop()
    }

    /// A call arriving while the pool is empty waits for a member rather than
    /// failing: an empty pool is a normal moment in a rolling restart.
    @Test("a call on an empty pool waits for a member", .timeLimit(.minutes(1)))
    func callWaitsForAMember() async throws {
        let alpha = try await Self.makeMember(named: "alpha")
        let script = Script(pending: [])
        await script.setAddress("alpha", String(alpha.url.dropFirst("unix://".count)))

        try await withRegistry(poolName: "mypool", script: script) { registry in
            let pool = try await AHAPool.open("aha://mypool", config: config(registry))
            #expect(await pool.memberNames.isEmpty)

            let call = Task { try await pool.call("whoami").stringValue }
            try await Task.sleep(for: .milliseconds(100))
            #expect(!call.isCancelled)

            // The member appears on the live stream, without it having to drop.
            await script.send([Self.add("alpha")])
            #expect(try await call.value == "alpha")
            await pool.close()
        }
        await alpha.stop()
    }

    /// `Proxy` never re-handshakes, so a member whose link dies stays dead. Left in
    /// the rotation it would poison every Nth call — and AHA cannot see a partition
    /// between this client and a member, so no `svc:del` is coming to clean it up.
    @Test("a member whose connection dies is evicted", .timeLimit(.minutes(2)))
    func deadMemberIsEvicted() async throws {
        let alpha = try await Self.makeMember(named: "alpha")
        let beta = try await Self.makeMember(named: "beta")
        let script = Script(pending: [Self.add("alpha"), Self.add("beta")])
        await script.setAddress("alpha", String(alpha.url.dropFirst("unix://".count)))
        await script.setAddress("beta", String(beta.url.dropFirst("unix://".count)))

        try await withRegistry(poolName: "mypool", script: script) { registry in
            let pool = try await AHAPool.open("aha://mypool", config: config(registry))
            try await waitForMembers(pool, count: 2)

            // beta dies without the registry ever saying so.
            await beta.stop()

            for _ in 0..<400 {
                if await pool.memberNames == ["alpha"] { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await pool.memberNames == ["alpha"],
                    "a dead member stayed in the pool")

            // And the survivor still serves every call.
            for _ in 0..<3 {
                #expect(try await pool.call("whoami").stringValue == "alpha")
            }
            await pool.close()
        }
        await alpha.stop()
    }

    /// `call`'s documented bound has to exist. A pool whose members are all down
    /// otherwise parks a caller forever with `callTimeout` set to any value.
    @Test("a call on a permanently empty pool honours callTimeout",
          .timeLimit(.minutes(1)))
    func emptyPoolHonoursCallTimeout() async throws {
        let script = Script(pending: [])
        try await withRegistry(poolName: "mypool", script: script) { registry in
            var config = self.config(registry)
            config.callTimeout = .milliseconds(300)
            let pool = try await AHAPool.open("aha://mypool", config: config)

            let started = ContinuousClock.now
            await #expect(throws: TelepathError.self) { _ = try await pool.call("whoami") }
            let elapsed = ContinuousClock.now - started
            #expect(elapsed < .seconds(5), "the call ignored callTimeout")
            await pool.close()
        }
    }

    /// Closing must not leave a waiter suspended forever, and must not leave the
    /// topology task running against a registry that is going away.
    @Test("closing releases a caller waiting on an empty pool", .timeLimit(.minutes(1)))
    func closeReleasesWaiters() async throws {
        let script = Script(pending: [])
        try await withRegistry(poolName: "mypool", script: script) { registry in
            let pool = try await AHAPool.open("aha://mypool", config: config(registry))
            let call = Task { try await pool.call("whoami") }
            try await Task.sleep(for: .milliseconds(100))
            await pool.close()
            await #expect(throws: (any Error).self) { _ = try await call.value }
        }
    }
}
