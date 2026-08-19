import Msgpack
import Testing
import TelepathTestKit
@testable import Telepath

/// Task cancellation while waiting on a server.
///
/// A bare `withCheckedThrowingContinuation` ignores cancellation, which left a
/// cancelled call suspended until the server replied or the socket dropped. That
/// also defeats anything built on cancellation — `withThrowingTaskGroup`,
/// `Task.timeout`, and swift-testing's own `.timeLimit`, which is why the
/// regression could hang past its own time limit.
struct CancellationTests {
    static let session = String(repeating: "ef", count: 16)

    private static func handshakeReply() -> MsgpackValue {
        .array([
            .string("tele:syn"),
            .map([
                .string("vers"): .array([.uint(3), .uint(0)]),
                .string("retn"): .array([.bool(true), .null]),
                .string("sess"): .string(session),
                .string("sharinfo"): .map([
                    .string("meths"): .map([
                        .string("quiet"): .map([:]),
                        .string("fast"): .map([:]),
                        .string("stream"): .map([.string("genr"): .bool(true)]),
                    ]),
                ]),
                .string("features"): .map([.string("tasks"): .uint(1)]),
            ]),
        ])
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

    @Test("cancelling a call in flight returns promptly", .timeLimit(.minutes(1)))
    func cancelUnaryCall() async throws {
        try await withDaemon { message, connection in
            if message.name == "tele:syn" {
                try await connection.send(Self.handshakeReply())
            }
            // t2:init is never answered.
        } _: { url in
            let proxy = try await Proxy.open(url)
            let task = Task { _ = try await proxy.call("quiet") }
            try await Task.sleep(for: .milliseconds(150))
            task.cancel()

            let started = ContinuousClock.now
            let result = await task.result
            #expect(ContinuousClock.now - started < .seconds(2))

            guard case .failure(let error) = result else {
                Issue.record("expected the cancelled call to fail")
                return
            }
            #expect(error is CancellationError)
            await proxy.close()
        }
    }

    /// A cancelled call's link must be closed, not pooled, for the same reason a
    /// timed-out one is: the reply may still arrive and would be handed to whoever
    /// takes the link next.
    @Test("a cancelled call's reply cannot leak into a later call", .timeLimit(.minutes(1)))
    func cancelledReplyDoesNotDesync() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply())
            case "t2:init":
                let method = message.todoMethod ?? ""
                if method == "quiet" {
                    try await Task.sleep(for: .milliseconds(600))
                }
                try await connection.send("t2:fini", [
                    .string("retn"): .array([.bool(true), .string(method)]),
                ])
            default:
                break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            let task = Task { _ = try await proxy.call("quiet") }
            try await Task.sleep(for: .milliseconds(150))
            task.cancel()
            _ = await task.result

            let value = try await proxy.call("fast")
            #expect(value.stringValue == "fast",
                    "a later call must not receive the cancelled call's reply")
            await proxy.close()
        }
    }

    @Test("cancelling a generator mid-stream returns promptly", .timeLimit(.minutes(1)))
    func cancelGenerator() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply())
            case "t2:init":
                try await connection.send("t2:genr", [:])
                try await connection.send("t2:yield", [
                    .string("retn"): .array([.bool(true), .uint(1)]),
                ])
                // ...and then nothing further.
            default:
                break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            let task = Task {
                var seen = 0
                for try await _ in proxy.stream("stream") { seen += 1 }
                return seen
            }
            try await Task.sleep(for: .milliseconds(200))
            task.cancel()

            let started = ContinuousClock.now
            _ = await task.result
            #expect(ContinuousClock.now - started < .seconds(2))
            await proxy.close()
        }
    }

    /// Cancellation can reach the event loop before the waiter is registered.
    @Test("cancelling immediately still completes", .timeLimit(.minutes(1)))
    func cancelBeforeRegistration() async throws {
        try await withDaemon { message, connection in
            if message.name == "tele:syn" {
                try await connection.send(Self.handshakeReply())
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            let task = Task { _ = try await proxy.call("quiet") }
            task.cancel()   // no sleep: races registration

            let started = ContinuousClock.now
            _ = await task.result
            #expect(ContinuousClock.now - started < .seconds(2))
            await proxy.close()
        }
    }
}
