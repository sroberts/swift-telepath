import Msgpack
import Testing
import TelepathTestKit
@testable import Telepath

/// `Config.callTimeout` bounds each wait for a server message.
///
/// A server that accepts a call and then goes quiet is indistinguishable from one
/// that is working hard, so the only way to test this is with a daemon that
/// deliberately stalls.
struct CallTimeoutTests {
    static let session = String(repeating: "cd", count: 16)

    private static func handshakeReply() -> MsgpackValue {
        .array([
            .string("tele:syn"),
            .map([
                .string("vers"): .array([.uint(3), .uint(0)]),
                .string("retn"): .array([.bool(true), .null]),
                .string("sess"): .string(session),
                .string("sharinfo"): .map([
                    .string("meths"): .map([
                        .string("slow"): .map([:]),
                        .string("fast"): .map([:]),
                        .string("stream"): .map([.string("genr"): .bool(true)]),
                    ]),
                ]),
                .string("features"): .map([.string("tasks"): .uint(1)]),
            ]),
        ])
    }

    private func config(timeout: Duration?) -> Config {
        var config = Config()
        config.callTimeout = timeout
        return config
    }

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

    @Test("a call that gets no reply fails with a timeout")
    func unaryTimeout() async throws {
        try await withDaemon { message, connection in
            if message.name == "tele:syn" {
                try await connection.send(Self.handshakeReply())
            }
            // t2:init is deliberately ignored: the server accepted the call and
            // then went quiet, which is the case a deadline exists for.
        } _: { url in
            let proxy = try await Proxy.open(url, config: config(timeout: .milliseconds(200)))
            do {
                _ = try await proxy.call("slow")
                Issue.record("expected the call to time out")
            } catch let error as TelepathError {
                guard case .timedOut = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
            }
            await proxy.close()
        }
    }

    /// The important one. A timed-out link must be closed, never pooled: the reply
    /// may still arrive, and a recycled link would hand it to the next call, which
    /// would silently receive another call's result.
    @Test("a late reply cannot leak into a later call")
    func lateReplyDoesNotDesync() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply())
            case "t2:init":
                let method = message.todoMethod ?? ""
                if method == "slow" {
                    // Replies long after the caller has given up.
                    try await Task.sleep(for: .milliseconds(600))
                }
                try await connection.send("t2:fini", [
                    .string("retn"): .array([.bool(true), .string(method)]),
                ])
            default:
                break
            }
        } _: { url in
            let proxy = try await Proxy.open(url, config: config(timeout: .milliseconds(150)))

            await #expect(throws: TelepathError.self) { try await proxy.call("slow") }

            // If the timed-out link had been recycled, this would return "slow".
            let value = try await proxy.call("fast")
            #expect(value.stringValue == "fast",
                    "a later call must not receive the abandoned call's reply")
            await proxy.close()
        }
    }

    /// For a generator the deadline bounds the gap between yields, so a stream that
    /// stalls partway is caught while a stream that keeps producing is not.
    @Test("a generator that stalls between yields times out")
    func generatorStallTimesOut() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply())
            case "t2:init":
                try await connection.send("t2:genr", [:])
                for i in 0..<3 {
                    try await connection.send("t2:yield", [
                        .string("retn"): .array([.bool(true), .uint(UInt64(i))]),
                    ])
                }
                // ...and then goes quiet without terminating the stream.
            default:
                break
            }
        } _: { url in
            let proxy = try await Proxy.open(url, config: config(timeout: .milliseconds(200)))
            var received: [MsgpackValue] = []
            do {
                for try await item in proxy.stream("stream") { received.append(item) }
                Issue.record("expected the stream to time out")
            } catch let error as TelepathError {
                guard case .timedOut = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
            }
            #expect(received.count == 3, "yields delivered before the stall are kept")
            await proxy.close()
        }
    }

    /// A slow but live stream must not be cut off: the deadline is a liveness
    /// check between messages, not a budget for the whole query.
    @Test("a slow but steady stream is not cut off by the deadline")
    func steadyStreamSurvives() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply())
            case "t2:init":
                try await connection.send("t2:genr", [:])
                // Each gap stays under the deadline while the total exceeds it.
                for i in 0..<6 {
                    try await Task.sleep(for: .milliseconds(60))
                    try await connection.send("t2:yield", [
                        .string("retn"): .array([.bool(true), .uint(UInt64(i))]),
                    ])
                }
                try await connection.send("t2:yield", [.string("retn"): .null])
            default:
                break
            }
        } _: { url in
            let proxy = try await Proxy.open(url, config: config(timeout: .milliseconds(250)))
            let items = try await proxy.stream("stream").collect()
            #expect(items.compactMap(\.intValue) == [0, 1, 2, 3, 4, 5])
            await proxy.close()
        }
    }

    /// The default is no deadline, matching Synapse, so a slow reply still lands.
    @Test("no deadline is set by default")
    func defaultIsUnbounded() async throws {
        #expect(Config().callTimeout == nil)

        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply())
            case "t2:init":
                try await Task.sleep(for: .milliseconds(400))
                try await connection.send("t2:fini", [
                    .string("retn"): .array([.bool(true), .string("eventually")]),
                ])
            default:
                break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            #expect(try await proxy.call("slow").stringValue == "eventually")
            await proxy.close()
        }
    }

    /// The handshake has its own budget, so a short call deadline does not make
    /// connecting fragile. Regression: binding it to connectTimeout instead made
    /// connecting to a cold Cortex fail, because accepting a socket and
    /// authenticating a session are not the same order of work.
    @Test("the handshake is not governed by the call deadline")
    func handshakeUsesOwnBudget() async throws {
        try await withDaemon { message, connection in
            if message.name == "tele:syn" {
                // Longer than callTimeout, well inside connectTimeout.
                try await Task.sleep(for: .milliseconds(400))
                try await connection.send(Self.handshakeReply())
            }
        } _: { url in
            var configuration = config(timeout: .milliseconds(100))
            configuration.connectTimeout = .seconds(5)
            #expect(configuration.handshakeTimeout == nil, "unbounded by default")
            let proxy = try await Proxy.open(url, config: configuration)
            #expect(await proxy.sessionIden == Self.session)
            await proxy.close()
        }
    }

    /// It is still available when a caller wants one.
    @Test("an explicit handshake deadline is enforced")
    func handshakeDeadlineWhenSet() async throws {
        try await withDaemon { message, _ in
            _ = message   // tele:syn is never answered
        } _: { url in
            var configuration = Config()
            configuration.handshakeTimeout = .milliseconds(200)
            do {
                let proxy = try await Proxy.open(url, config: configuration)
                await proxy.close()
                Issue.record("expected the handshake to time out")
            } catch let error as TelepathError {
                guard case .timedOut = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
            }
        }
    }
}
