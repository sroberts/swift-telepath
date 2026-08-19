import Msgpack
import Testing
import TelepathTestKit
@testable import Telepath

/// Pool behaviour: Synapse keeps four idle links, opens replacements in the
/// background below that, and culls at most one per interval above twelve.
struct PoolTests {
    static let session = String(repeating: "01", count: 16)

    private static func handshakeReply() -> MsgpackValue {
        .array([
            .string("tele:syn"),
            .map([
                .string("vers"): .array([.uint(3), .uint(0)]),
                .string("retn"): .array([.bool(true), .null]),
                .string("sess"): .string(session),
                .string("sharinfo"): .map([.string("meths"): .map([.string("ping"): .map([:])])]),
                .string("features"): .map([.string("tasks"): .uint(1)]),
            ]),
        ])
    }

    /// Counts connections so pool growth is observable from the server side.
    private actor Connections {
        var count = 0
        func record() { count += 1 }
    }

    @Test("links are opened in the background to reach the low water mark")
    func lowWaterPrefill() async throws {
        let connections = Connections()
        let daemon = try await FakeDaemon.start { message, connection in
            switch message.name {
            case "tele:syn":
                await connections.record()
                try await connection.send(Self.handshakeReply())
            case "t2:init":
                await connections.record()
                try await connection.send("t2:fini", [
                    .string("retn"): .array([.bool(true), .string("pong")]),
                ])
            default:
                break
            }
        }
        defer { Task { await daemon.stop() } }

        var config = Config()
        config.poolLowWater = 4
        let proxy = try await Proxy.open(daemon.url, config: config)

        // One call takes a link, which drops the pool below the mark and triggers
        // background fills.
        #expect(try await proxy.call("ping").stringValue == "pong")

        // Give the background opens a moment to land.
        try await Task.sleep(for: .milliseconds(400))
        #expect(await proxy.idleLinkCount >= 1,
                "the pool should have opened spare links in the background")
        #expect(await proxy.idleLinkCount <= config.poolHighWater)
        await proxy.close()
    }

    /// A proxy that is never called must not open spare connections: filling is
    /// reactive so an idle client on a metered link stays quiet.
    @Test("an unused proxy opens no spare links")
    func noEagerPrefill() async throws {
        let daemon = try await FakeDaemon.start { message, connection in
            if message.name == "tele:syn" {
                try await connection.send(Self.handshakeReply())
            }
        }
        defer { Task { await daemon.stop() } }

        let proxy = try await Proxy.open(daemon.url)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await proxy.idleLinkCount == 0)
        await proxy.close()
    }

    @Test("closing the proxy drains the pool")
    func closeDrainsPool() async throws {
        let daemon = try await FakeDaemon.start { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply())
            case "t2:init":
                try await connection.send("t2:fini", [
                    .string("retn"): .array([.bool(true), .string("pong")]),
                ])
            default:
                break
            }
        }
        defer { Task { await daemon.stop() } }

        let proxy = try await Proxy.open(daemon.url)
        _ = try await proxy.call("ping")
        try await Task.sleep(for: .milliseconds(300))
        await proxy.close()
        #expect(await proxy.idleLinkCount == 0)
    }
}
