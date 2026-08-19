import Foundation
import Msgpack
import Testing
import TelepathTestKit
@testable import Telepath

/// Dynamically shared objects.
///
/// Two things distinguish a share from a generator: the link is free the moment
/// the reply lands, because the share is addressed by iden afterwards, and
/// teardown travels on the proxy's *main* link rather than a pool link.
struct ShareTests {
    static let session = String(repeating: "23", count: 16)
    static let shareIden = String(repeating: "9f", count: 16)

    private static func handshakeReply() -> MsgpackValue {
        .array([
            .string("tele:syn"),
            .map([
                .string("vers"): .array([.uint(3), .uint(0)]),
                .string("retn"): .array([.bool(true), .null]),
                .string("sess"): .string(session),
                .string("sharinfo"): .map([
                    .string("meths"): .map([
                        .string("upload"): .map([:]),
                        .string("plain"): .map([:]),
                    ]),
                ]),
                .string("features"): .map([.string("tasks"): .uint(1)]),
            ]),
        ])
    }

    private static func shareReply() -> MsgpackValue {
        .array([
            .string("t2:share"),
            .map([
                .string("iden"): .string(shareIden),
                .string("sharinfo"): .map([
                    .string("meths"): .map([
                        .string("write"): .map([:]),
                        .string("items"): .map([.string("genr"): .bool(true)]),
                    ]),
                ]),
            ]),
        ])
    }

    /// Records what the daemon saw, including which connection carried it, so the
    /// main-link requirement is testable.
    private actor Observed {
        var mainConnection: ObjectIdentifier?
        var shareFiniConnection: ObjectIdentifier?
        var callNames: [String?] = []
        var shareFiniIden: String?

        func recordMain(_ id: ObjectIdentifier) { mainConnection = id }
        func recordCall(name: String?) { callNames.append(name) }
        func recordShareFini(_ id: ObjectIdentifier, iden: String?) {
            shareFiniConnection = id
            shareFiniIden = iden
        }
    }

    private func standardDaemon(_ observed: Observed) -> FakeDaemon.Handler {
        { message, connection in
            switch message.name {
            case "tele:syn":
                await observed.recordMain(ObjectIdentifier(connection))
                try await connection.send(Self.handshakeReply())
            case "t2:init":
                // The share's iden arrives as `name` on subsequent calls.
                await observed.recordCall(name: message["name"]?.stringValue)
                if message.todoMethod == "upload" {
                    try await connection.send(Self.shareReply())
                } else {
                    try await connection.send("t2:fini", [
                        .string("retn"): .array([.bool(true), .string(message.todoMethod ?? "")]),
                    ])
                }
            case "share:fini":
                await observed.recordShareFini(ObjectIdentifier(connection),
                                               iden: message["share"]?.stringValue)
            default:
                break
            }
        }
    }

    @Test("a t2:share reply becomes a Share carrying its iden and methods")
    func callForShare() async throws {
        let observed = Observed()
        let daemon = try await FakeDaemon.start(handler: standardDaemon(observed))
        defer { Task { await daemon.stop() } }

        let proxy = try await Proxy.open(daemon.url)
        let share = try await proxy.callForShare("upload")

        #expect(share.iden == Self.shareIden)
        #expect(share.methods["write"]?.isGenerator == false)
        #expect(share.methods["items"]?.isGenerator == true)
        await proxy.close()
    }

    /// The link is returned immediately, so a share does not tie up a connection
    /// the way a generator does.
    @Test("the link is released as soon as the share reply lands")
    func linkIsReleasedImmediately() async throws {
        let observed = Observed()
        let daemon = try await FakeDaemon.start(handler: standardDaemon(observed))
        defer { Task { await daemon.stop() } }

        let proxy = try await Proxy.open(daemon.url)
        _ = try await proxy.callForShare("upload")
        #expect(await proxy.idleLinkCount >= 1, "the share's link should be back in the pool")
        await proxy.close()
    }

    @Test("calls on a share carry its iden as the target name")
    func callsAddressTheShare() async throws {
        let observed = Observed()
        let daemon = try await FakeDaemon.start(handler: standardDaemon(observed))
        defer { Task { await daemon.stop() } }

        let proxy = try await Proxy.open(daemon.url)
        let share = try await proxy.callForShare("upload")
        _ = try await share.call("write")

        // callNames is [String?], so index rather than use first/last, which would
        // compare a doubly-optional and never match nil.
        let names = await observed.callNames
        #expect(names.count == 2)
        #expect(names[0] == nil, "the opening call targets the session's root object")
        #expect(names[1] == Self.shareIden, "the share call targets the share by iden")
        await proxy.close()
    }

    /// Teardown goes on the main link. Sending it on a pool link would reach a
    /// connection the daemon does not associate with the session's shares.
    @Test("share:fini is sent on the main link, not a pool link")
    func teardownUsesMainLink() async throws {
        let observed = Observed()
        let daemon = try await FakeDaemon.start(handler: standardDaemon(observed))
        defer { Task { await daemon.stop() } }

        let proxy = try await Proxy.open(daemon.url)
        let share = try await proxy.callForShare("upload")
        await share.close()

        // Give the teardown a moment to arrive.
        try await Task.sleep(for: .milliseconds(200))
        let main = await observed.mainConnection
        let fini = await observed.shareFiniConnection
        #expect(fini != nil, "share:fini should have been sent")
        #expect(fini == main, "share:fini must travel on the main link")
        #expect(await observed.shareFiniIden == Self.shareIden)
        await proxy.close()
    }

    @Test("closing twice is harmless and calling afterwards fails")
    func closedShareRejectsCalls() async throws {
        let observed = Observed()
        let daemon = try await FakeDaemon.start(handler: standardDaemon(observed))
        defer { Task { await daemon.stop() } }

        let proxy = try await Proxy.open(daemon.url)
        let share = try await proxy.callForShare("upload")
        await share.close()
        await share.close()

        await #expect(throws: TelepathError.self) { try await share.call("write") }
        #expect(await share.isClosed)
        await proxy.close()
    }

    @Test("callForShare on a method that returns a value reports the mismatch")
    func nonShareMethod() async throws {
        let observed = Observed()
        let daemon = try await FakeDaemon.start(handler: standardDaemon(observed))
        defer { Task { await daemon.stop() } }

        let proxy = try await Proxy.open(daemon.url)
        do {
            _ = try await proxy.callForShare("plain")
            Issue.record("expected a protocol error")
        } catch let error as TelepathError {
            guard case .protocolViolation(let text) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(text.contains("not a share"))
        }
        await proxy.close()
    }

    /// Spec 3.4: an unrecognised main-link message is logged and dropped. Treating
    /// it as an error would break the client against any release that adds one.
    @Test("an unknown message on the main link is ignored")
    func unknownMainLinkMessage() async throws {
        let daemon = try await FakeDaemon.start { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply())
                // Unsolicited, and of a kind this client does not implement.
                try await connection.send("some:future:message", [.string("x"): .uint(1)])
                try await connection.send("share:data", [
                    .string("share"): .string(Self.shareIden),
                    .string("data"): .array([.bool(true), .string("ignored")]),
                ])
            case "t2:init":
                try await connection.send("t2:fini", [
                    .string("retn"): .array([.bool(true), .string("still fine")]),
                ])
            default:
                break
            }
        }
        defer { Task { await daemon.stop() } }

        let proxy = try await Proxy.open(daemon.url)
        try await Task.sleep(for: .milliseconds(200))
        // The connection survived and calls still work.
        #expect(try await proxy.call("plain").stringValue == "still fine")
        await proxy.close()
    }
}
