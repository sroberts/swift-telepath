import Msgpack
import TelepathTestKit
import Testing
@testable import Telepath

/// spec.md M6. `Proxy.state` exists so a caller can reconnect on its own terms,
/// which only works if the signal is both truthful about what ended the session
/// and free of the retain cycle an `AsyncStream` invites.
@Suite struct ProxyStateTests {
    private static let session = "0123456789abcdef0123456789abcdef"

    private static func handshakeReply() -> MsgpackValue {
        .array([
            .string("tele:syn"),
            .map([
                .string("vers"): .array([.uint(3), .uint(0)]),
                .string("retn"): .array([.bool(true), .null]),
                .string("sess"): .string(session),
                .string("sharinfo"): .map([
                    .string("meths"): .map([
                        .string("fast"): .map([:]),
                        .string("quiet"): .map([:]),
                    ]),
                ]),
                .string("features"): .map([.string("tasks"): .uint(1)]),
            ]),
        ])
    }

    /// Replies to the handshake, then behaves as the scenario requires.
    private func withDaemon<T>(
        handler: @escaping FakeDaemon.Handler,
        _ body: (String) async throws -> T
    ) async throws -> T {
        let daemon = try await FakeDaemon.start(handler: handler)
        do {
            let result = try await body(daemon.url)
            await daemon.stop()
            return result
        } catch {
            await daemon.stop()
            throw error
        }
    }

    private static let handshakeOnly: FakeDaemon.Handler = { message, connection in
        if message.name == "tele:syn" {
            try await connection.send(handshakeReply())
        }
    }

    /// The first element is always the current state, so a caller that subscribes
    /// after opening is not left guessing until something changes.
    @Test("a new observer is told the session is up")
    func reportsConnected() async throws {
        try await withDaemon(handler: Self.handshakeOnly) { url in
            let proxy = try await Proxy.open(url)
            var iterator = proxy.state.makeAsyncIterator()
            let first = await iterator.next()
            guard case .connected? = first else {
                Issue.record("expected .connected, got \(String(describing: first))")
                return
            }
            await proxy.close()
        }
    }

    /// A server hanging up cleanly reads as orderly and is easy to mistake for
    /// nothing having happened. It is still the end of the session.
    @Test("a server closing the main link reports disconnected", .timeLimit(.minutes(1)))
    func reportsCleanClose() async throws {
        try await withDaemon(handler: { message, connection in
            if message.name == "tele:syn" {
                try await connection.send(Self.handshakeReply())
                try await Task.sleep(for: .milliseconds(50))
                await connection.close()
            }
        }) { url in
            let proxy = try await Proxy.open(url)
            var seen: [Proxy.State] = []
            for await state in proxy.state {
                seen.append(state)
                if case .disconnected = state { break }
            }
            #expect(seen.count == 2, "expected connected then disconnected")
            guard case .disconnected? = seen.last else {
                Issue.record("expected .disconnected, got \(String(describing: seen.last))")
                return
            }
            await proxy.close()
        }
    }

    /// The other half of the same criterion: the server dying rather than hanging
    /// up politely.
    @Test("a server that dies reports disconnected", .timeLimit(.minutes(1)))
    func reportsServerDeath() async throws {
        let daemon = try await FakeDaemon.start(handler: Self.handshakeOnly)
        let proxy = try await Proxy.open(daemon.url)

        var iterator = proxy.state.makeAsyncIterator()
        _ = await iterator.next()          // .connected
        await daemon.stop()

        let next = await iterator.next()
        guard case .disconnected? = next else {
            Issue.record("expected .disconnected, got \(String(describing: next))")
            return
        }
        await proxy.close()
    }

    /// The `catch` path, as opposed to the clean end of stream every other
    /// disconnect test reaches. Mutation testing found it unexercised: deleting the
    /// report from `readMainLink`'s error branch broke nothing until this existed.
    ///
    /// `0xc1` is the byte msgpack reserves and never emits. The stream is unframed
    /// and has no resync point, so a codec error on the main link is unrecoverable
    /// — unlike an unknown *message name*, which §3.4 requires be dropped.
    @Test("malformed bytes on the main link report disconnected", .timeLimit(.minutes(1)))
    func reportsCodecFailure() async throws {
        try await withDaemon(handler: { message, connection in
            if message.name == "tele:syn" {
                try await connection.send(Self.handshakeReply())
                try await Task.sleep(for: .milliseconds(50))
                try await connection.sendRaw([0xc1])
            }
        }) { url in
            let proxy = try await Proxy.open(url)
            var iterator = proxy.state.makeAsyncIterator()
            _ = await iterator.next()          // .connected
            let next = await iterator.next()
            guard case .disconnected(let error)? = next else {
                Issue.record("expected .disconnected, got \(String(describing: next))")
                return
            }
            #expect(!(error is TelepathError), "expected the codec error, not a close")
            await proxy.close()
        }
    }

    /// The criterion this suite corrected before implementing it. A timed-out call
    /// closes its own pool link; the main link and the session are untouched, and
    /// reporting a disconnect here would make the signal useless for the one thing
    /// it exists to report.
    @Test("a timed-out call does not end the session", .timeLimit(.minutes(1)))
    func timedOutCallIsNotADisconnect() async throws {
        try await withDaemon(handler: { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply())
            case "t2:init":
                // Accept the call and go quiet, which is what a deadline is for.
                break
            default:
                break
            }
        }) { url in
            var config = Config()
            config.callTimeout = .milliseconds(200)
            let proxy = try await Proxy.open(url, config: config)

            await #expect(throws: (any Error).self) { _ = try await proxy.call("quiet") }

            // The session must still be reported as up.
            var iterator = proxy.state.makeAsyncIterator()
            let state = await iterator.next()
            guard case .connected? = state else {
                Issue.record("a timed-out call ended the session: \(String(describing: state))")
                return
            }
            await proxy.close()
        }
    }

    /// Closing is not a failure, so it finishes the stream rather than reporting a
    /// disconnect a caller might try to reconnect from.
    @Test("closing finishes the stream without reporting a disconnect")
    func closeFinishesCleanly() async throws {
        try await withDaemon(handler: Self.handshakeOnly) { url in
            let proxy = try await Proxy.open(url)
            let stream = proxy.state
            let collector = Task {
                var seen: [Proxy.State] = []
                for await state in stream { seen.append(state) }
                return seen
            }
            try await Task.sleep(for: .milliseconds(50))
            await proxy.close()
            let states = await collector.value
            #expect(states.count == 1)
            guard case .connected? = states.first else {
                Issue.record("expected only .connected before the stream finished")
                return
            }
        }
    }

    /// An observer arriving after the session ended must be told at once, not left
    /// waiting on an event that can never arrive.
    @Test("an observer arriving after the drop is told immediately", .timeLimit(.minutes(1)))
    func lateObserverIsToldAtOnce() async throws {
        let daemon = try await FakeDaemon.start(handler: Self.handshakeOnly)
        let proxy = try await Proxy.open(daemon.url)

        var first = proxy.state.makeAsyncIterator()
        _ = await first.next()
        await daemon.stop()
        guard case .disconnected? = await first.next() else {
            Issue.record("the first observer never saw the drop")
            return
        }

        var late = proxy.state.makeAsyncIterator()
        guard case .disconnected? = await late.next() else {
            Issue.record("a late observer was not told the session had ended")
            return
        }
        if case .some(let extra) = await late.next() {
            Issue.record("the late stream should have finished, got \(extra)")
        }
        await proxy.close()
    }

    /// `AsyncStream` retains its `onTermination` handler, so a handler capturing the
    /// proxy would keep an actor and its event loop group alive for as long as
    /// anyone held the stream — or forever, for a stream nobody drains.
    @Test("holding a stream does not keep the proxy alive")
    func streamDoesNotRetainTheProxy() async throws {
        try await withDaemon(handler: Self.handshakeOnly) { url in
            weak var weakProxy: Proxy?
            var stream: AsyncStream<Proxy.State>?

            do {
                let proxy = try await Proxy.open(url)
                weakProxy = proxy
                stream = proxy.state          // deliberately never drained
                #expect(weakProxy != nil)
                await proxy.close()
            }

            #expect(weakProxy == nil, "the undrained stream kept the proxy alive")
            _ = stream                        // keep it in scope across the check
            stream = nil
        }
    }

    /// Termination has to deregister, or a long-lived proxy accumulates a
    /// continuation per observer that ever existed.
    @Test("a terminated stream deregisters its observer")
    func terminationDeregisters() async throws {
        let broadcaster = ProxyStateBroadcaster()
        do {
            var iterator = broadcaster.makeStream().makeAsyncIterator()
            _ = await iterator.next()
            #expect(broadcaster.observerCount == 1)
        }
        // Termination runs when the stream is deallocated, which is not necessarily
        // synchronous with leaving scope.
        for _ in 0..<100 where broadcaster.observerCount != 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(broadcaster.observerCount == 0)
    }

    /// The point of the whole milestone: the caller, not the library, decides to
    /// reconnect, and opening a new proxy is what actually rebuilds the session.
    @Test("a caller can reconnect by opening a new proxy", .timeLimit(.minutes(1)))
    func callerDrivenReconnect() async throws {
        let daemon = try await FakeDaemon.start(handler: Self.handshakeOnly)
        let url = daemon.url
        let proxy = try await Proxy.open(url)

        var iterator = proxy.state.makeAsyncIterator()
        _ = await iterator.next()
        await daemon.stop()
        guard case .disconnected? = await iterator.next() else {
            Issue.record("never saw the disconnect that should trigger a reconnect")
            return
        }
        await proxy.close()

        // The caller's policy: the session ended, so build a new one. A restarted
        // server issues a new session iden, which is exactly why the old proxy
        // cannot be repaired in place.
        let socketPath = String(url.dropFirst("unix://".count))
        let restarted = try await FakeDaemon.start(socketPath: socketPath, handler: { message, connection in
            if message.name == "tele:syn" {
                try await connection.send(Self.handshakeReply())
                return
            }
            if message.name == "t2:init" {
                try await connection.send("t2:fini", [
                    .string("retn"): .array([.bool(true), .string("alive")]),
                ])
            }
        })
        let reconnected = try await Proxy.open(url)
        let value = try await reconnected.call("fast")
        #expect(value.stringValue == "alive")
        await reconnected.close()
        await restarted.stop()
    }
}
