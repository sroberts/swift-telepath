import Msgpack
import Synapse
import Telepath
import TelepathTestKit
import Testing

/// Synapse 3.0 restructured the node payload, and `Node` decodes a 3.x node
/// without error while getting every property wrong. The facade refuses such a
/// server rather than returning data that looks right; these pin that it does,
/// and that it does not over-reach and refuse servers it can actually serve.
@Suite struct VersionGateTests {
    private static let session = "0123456789abcdef0123456789abcdef"

    private static func reply(version: MsgpackValue?) -> MsgpackValue {
        var sharinfo: [MsgpackValue: MsgpackValue] = [
            .string("meths"): .map([.string("storm"): .map([.string("genr"): .bool(true)])]),
        ]
        if let version { sharinfo[.string("syn:version")] = version }
        return .array([
            .string("tele:syn"),
            .map([
                .string("vers"): .array([.uint(3), .uint(0)]),
                .string("retn"): .array([.bool(true), .null]),
                .string("sess"): .string(session),
                .string("sharinfo"): .map(sharinfo),
                .string("features"): .map([:]),
            ]),
        ])
    }

    private func withServer<T>(version: MsgpackValue?,
                               _ body: (String) async throws -> T) async throws -> T {
        let daemon = try await FakeDaemon.start { message, connection in
            if message.name == "tele:syn" {
                try await connection.send(Self.reply(version: version))
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

    @Test("a 3.x server is refused rather than silently mis-decoded")
    func rejectsSynapse3() async throws {
        try await withServer(version: .string("3.0.0")) { url in
            do {
                _ = try await Cortex.open(url)
                Issue.record("expected Cortex.open to refuse a 3.x server")
            } catch let error as CortexError {
                guard case .unsupportedSynapseVersion(let reported) = error else {
                    Issue.record("wrong CortexError case")
                    return
                }
                #expect(reported == [3, 0, 0])
                // The message has to name the escape hatch, or the refusal just
                // looks like the library not working.
                #expect(error.description.contains("3.0.0"))
                #expect(error.description.contains("Proxy"))
            }
        }
    }

    @Test("a 2.x server is accepted")
    func acceptsSynapse2() async throws {
        try await withServer(version: .array([.uint(2), .uint(249), .uint(0)])) { url in
            let cortex = try await Cortex.open(url)
            #expect(await cortex.proxy.serverVersion == [2, 249, 0])
            await cortex.close()
        }
    }

    /// Absence is not evidence of a version we reject, and a peer too old to
    /// report one has already failed the handshake on its missing session iden.
    @Test("a server reporting no version is allowed through")
    func acceptsUnreportedVersion() async throws {
        try await withServer(version: nil) { url in
            let cortex = try await Cortex.open(url)
            #expect(await cortex.proxy.serverVersion == nil)
            await cortex.close()
        }
    }

    /// Rejecting must not leak the connection that discovered the version. The
    /// proxy owns an event loop group, and SWIFTNIO_STRICT turns a leak into a
    /// crash rather than a line of stderr nobody reads.
    @Test("a refused server leaves nothing running")
    func refusalClosesTheProxy() async throws {
        try await withServer(version: .string("3.0.0")) { url in
            for _ in 0..<5 {
                await #expect(throws: CortexError.self) { _ = try await Cortex.open(url) }
            }
        }
    }
}
