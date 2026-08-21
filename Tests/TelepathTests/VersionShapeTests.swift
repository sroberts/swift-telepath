import Msgpack
import Telepath
import TelepathTestKit
import Testing

/// Synapse reports its own version as a tuple in 2.x and a dotted string in 3.0,
/// and 3.0's one remaining feature carries a string version too. A live server
/// proves only one shape at a time, and no Cortex advertises a string feature at
/// all, so the shapes are pinned here against a scripted daemon.
@Suite struct VersionShapeTests {
    private static let session = "0123456789abcdef0123456789abcdef"

    private static func reply(version: MsgpackValue, features: MsgpackValue) -> MsgpackValue {
        .array([
            .string("tele:syn"),
            .map([
                .string("vers"): .array([.uint(3), .uint(0)]),
                .string("retn"): .array([.bool(true), .null]),
                .string("sess"): .string(session),
                .string("sharinfo"): .map([
                    .string("meths"): .map([.string("ping"): .map([:])]),
                    .string("syn:version"): version,
                ]),
                .string("features"): features,
            ]),
        ])
    }

    private func check(version: MsgpackValue, features: MsgpackValue,
                       _ body: @Sendable (Proxy) async throws -> Void) async throws {
        let daemon = try await FakeDaemon.start { message, connection in
            if message.name == "tele:syn" {
                try await connection.send(Self.reply(version: version, features: features))
            }
        }
        let proxy = try await Proxy.open(daemon.url)
        try await body(proxy)
        await proxy.close()
        await daemon.stop()
    }

    @Test("a 3.0 dotted-string syn:version parses")
    func stringVersion() async throws {
        try await check(version: .string("3.0.0"), features: .map([:])) { proxy in
            #expect(await proxy.serverVersion == [3, 0, 0])
        }
    }

    @Test("a 2.x tuple syn:version still parses")
    func tupleVersion() async throws {
        try await check(version: .array([.uint(2), .uint(249), .uint(0)]), features: .map([:])) { proxy in
            #expect(await proxy.serverVersion == [2, 249, 0])
        }
    }

    @Test("a non-numeric version is nil rather than a partial parse")
    func junkVersion() async throws {
        try await check(version: .string("3.0.0-rc1"), features: .map([:])) { proxy in
            #expect(await proxy.serverVersion == nil)
        }
    }

    @Test("a string-valued feature scores by major version")
    func stringFeature() async throws {
        try await check(version: .string("3.0.0"),
                        features: .map([.string("stormservice"): .string("1.0.0")])) { proxy in
            #expect(await proxy.hasFeature("stormservice"))
            #expect(await proxy.features["stormservice"] == 1)
            #expect(await !proxy.hasFeature("stormservice", minVersion: 2))
        }
    }

    @Test("an integer-valued feature still scores")
    func intFeature() async throws {
        try await check(version: .string("3.0.0"),
                        features: .map([.string("tasks"): .uint(1)])) { proxy in
            #expect(await proxy.hasFeature("tasks"))
        }
    }
}
