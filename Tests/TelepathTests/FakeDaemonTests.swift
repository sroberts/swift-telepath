import Msgpack
import Testing
import TelepathTestKit
@testable import Telepath

/// Failure-path coverage. The live-Cortex suite proves the happy path; these are
/// the cases a healthy server will not produce on demand, and they are where a
/// client normally hangs, leaks a link, or reports the wrong error.
struct FakeDaemonTests {
    static let session = String(repeating: "ab", count: 16)

    /// A well-formed handshake reply, with fields overridable per scenario.
    static func handshakeReply(
        version: [MsgpackValue] = [.uint(3), .uint(0)],
        session: String? = FakeDaemonTests.session,
        retn: MsgpackValue = .array([.bool(true), .null]),
        methods: [String: Bool] = ["getCellInfo": false, "storm": true]
    ) -> MsgpackValue {
        var meths: [MsgpackValue: MsgpackValue] = [:]
        for (name, isGenerator) in methods {
            meths[.string(name)] = isGenerator ? .map([.string("genr"): .bool(true)]) : .map([:])
        }
        var info: [MsgpackValue: MsgpackValue] = [
            .string("vers"): .array(version),
            .string("retn"): retn,
            .string("sharinfo"): .map([
                .string("meths"): .map(meths),
                .string("syn:version"): .array([.uint(2), .uint(249), .uint(0)]),
            ]),
            .string("features"): .map([.string("tasks"): .uint(1), .string("tellready"): .uint(1)]),
        ]
        if let session { info[.string("sess")] = .string(session) }
        return .array([.string("tele:syn"), .map(info)])
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

    // MARK: - Handshake

    @Test("a rejected handshake surfaces the server's AuthDeny")
    func handshakeAuthFailure() async throws {
        try await withDaemon { message, connection in
            guard message.name == "tele:syn" else { return }
            try await connection.send(Self.handshakeReply(retn: .array([
                .bool(false),
                .array([.string("AuthDeny"), .map([.string("mesg"): .string("Invalid password")])]),
            ])))
        } _: { url in
            do {
                _ = try await Proxy.open(url)
                Issue.record("expected the handshake to fail")
            } catch let error as TelepathRemoteError {
                #expect(error.kind == .authDeny)
                #expect(error.mesg == "Invalid password")
            }
        }
    }

    /// Only the major version is compatibility-significant.
    @Test("a mismatched protocol major version is fatal")
    func versionMismatch() async throws {
        try await withDaemon { message, connection in
            guard message.name == "tele:syn" else { return }
            try await connection.send(Self.handshakeReply(version: [.uint(2), .uint(0)]))
        } _: { url in
            do {
                _ = try await Proxy.open(url)
                Issue.record("expected a version mismatch")
            } catch let error as TelepathError {
                guard case .versionMismatch(let theirs, _) = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
                #expect(theirs == [2, 0])
            }
        }
    }

    @Test("a differing protocol minor version is accepted")
    func minorVersionTolerated() async throws {
        try await withDaemon { message, connection in
            guard message.name == "tele:syn" else { return }
            try await connection.send(Self.handshakeReply(version: [.uint(3), .uint(7)]))
        } _: { url in
            let proxy = try await Proxy.open(url)
            #expect(await proxy.protocolVersion == [3, 7])
            await proxy.close()
        }
    }

    /// A missing session iden means a pre-2.166 peer offering only task v1.
    /// Detected explicitly rather than degrading into an unsupported code path.
    @Test("a handshake without a session iden reports task v1 as unsupported")
    func taskV1Detected() async throws {
        try await withDaemon { message, connection in
            guard message.name == "tele:syn" else { return }
            try await connection.send(Self.handshakeReply(session: nil))
        } _: { url in
            do {
                _ = try await Proxy.open(url)
                Issue.record("expected task v1 to be rejected")
            } catch let error as TelepathError {
                #expect(error == .taskV1NotSupported)
            }
        }
    }

    @Test("method metadata and features are captured from the handshake")
    func handshakeMetadata() async throws {
        try await withDaemon { message, connection in
            guard message.name == "tele:syn" else { return }
            try await connection.send(Self.handshakeReply())
        } _: { url in
            let proxy = try await Proxy.open(url)
            #expect(await proxy.sessionIden == Self.session)
            #expect(await proxy.methods["storm"]?.isGenerator == true)
            #expect(await proxy.methods["getCellInfo"]?.isGenerator == false)
            #expect(await proxy.hasFeature("tasks"))
            #expect(await proxy.hasFeature("tasks", minVersion: 2) == false)
            #expect(await proxy.serverVersion == [2, 249, 0])
            await proxy.close()
        }
    }

    // MARK: - Calls

    /// Pool links skip the handshake entirely, so the session iden is the only
    /// thing binding them to an authenticated session. If it were omitted the
    /// server would reject every call.
    @Test("a pool link sends the session iden and no handshake")
    func poolLinkCarriesSession() async throws {
        let observed = Observed()
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply())
            case "t2:init":
                await observed.record(session: message["sess"]?.stringValue,
                                      method: message.todoMethod)
                try await connection.send("t2:fini", [.string("retn"): .array([.bool(true), .uint(7)])])
            default:
                break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            let value = try await proxy.call("getCellInfo")
            #expect(value.intValue == 7)
            #expect(await observed.session == Self.session)
            #expect(await observed.method == "getCellInfo")
            await proxy.close()
        }
    }

    /// A remote exception is a complete exchange, not a transport failure, so the
    /// link stays clean and the proxy must remain usable.
    @Test("a remote exception is raised and the proxy still works")
    func remoteException() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn":
                try await connection.send(Self.handshakeReply())
            case "t2:init":
                if message.todoMethod == "boom" {
                    try await connection.send("t2:fini", [.string("retn"): .array([
                        .bool(false),
                        .array([.string("NoSuchMeth"), .map([
                            .string("mesg"): .string("no such method: boom"),
                            .string("efile"): .string("daemon.py"),
                            .string("eline"): .uint(120),
                        ])]),
                    ])])
                } else {
                    try await connection.send("t2:fini", [.string("retn"): .array([.bool(true), .string("ok")])])
                }
            default: break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            do {
                _ = try await proxy.call("boom")
                Issue.record("expected a remote error")
            } catch let error as TelepathRemoteError {
                #expect(error.kind == .noSuchMeth)
                #expect(error.mesg == "no such method: boom")
                #expect(error.file == "daemon.py")
                #expect(error.line == 120)
            }
            // The link was returned to the pool, so the next call succeeds.
            #expect(try await proxy.call("fine").stringValue == "ok")
            await proxy.close()
        }
    }

    @Test("an unrecognised exception name still decodes")
    func unknownExceptionName() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn": try await connection.send(Self.handshakeReply())
            case "t2:init":
                try await connection.send("t2:fini", [.string("retn"): .array([
                    .bool(false),
                    .array([.string("SomeFutureError"), .map([.string("mesg"): .string("from a newer Synapse")])]),
                ])])
            default: break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            do {
                _ = try await proxy.call("anything")
                Issue.record("expected a remote error")
            } catch let error as TelepathRemoteError {
                #expect(error.kind == .other("SomeFutureError"))
                #expect(error.mesg == "from a newer Synapse")
            }
            await proxy.close()
        }
    }

    @Test("calling a generator method with call() is reported, not drained")
    func generatorViaCall() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn": try await connection.send(Self.handshakeReply())
            case "t2:init": try await connection.send("t2:genr", [:])
            default: break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            do {
                _ = try await proxy.call("storm")
                Issue.record("expected a protocol error")
            } catch let error as TelepathError {
                guard case .protocolViolation(let text) = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
                #expect(text.contains("stream"))
            }
            await proxy.close()
        }
    }

    @Test("a dynamic share reply is reported as unsupported rather than hanging")
    func shareUnsupported() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn": try await connection.send(Self.handshakeReply())
            case "t2:init":
                try await connection.send("t2:share", [
                    .string("iden"): .string(String(repeating: "c", count: 32)),
                    .string("sharinfo"): .map([.string("meths"): .map([:])]),
                ])
            default: break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            await #expect(throws: TelepathError.self) { try await proxy.call("getLayer") }
            await proxy.close()
        }
    }

    // MARK: - Generators

    @Test("a generator streams yields and ends on a null retn")
    func generatorHappyPath() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn": try await connection.send(Self.handshakeReply())
            case "t2:init":
                try await connection.send("t2:genr", [:])
                for i in 0..<5 {
                    try await connection.send("t2:yield", [.string("retn"): .array([.bool(true), .uint(UInt64(i))])])
                }
                try await connection.send("t2:yield", [.string("retn"): .null])
            default: break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            let items = try await proxy.stream("storm").collect()
            #expect(items.compactMap(\.intValue) == [0, 1, 2, 3, 4])
            await proxy.close()
        }
    }

    /// An exception mid-stream terminates it cleanly, so the link is still reusable.
    @Test("an exception mid-generator terminates the stream and is raised")
    func generatorException() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn": try await connection.send(Self.handshakeReply())
            case "t2:init":
                if message.todoMethod == "storm" {
                    try await connection.send("t2:genr", [:])
                    try await connection.send("t2:yield", [.string("retn"): .array([.bool(true), .uint(1)])])
                    try await connection.send("t2:yield", [.string("retn"): .array([
                        .bool(false),
                        .array([.string("BadSyntax"), .map([.string("mesg"): .string("bad query")])]),
                    ])])
                } else {
                    try await connection.send("t2:fini", [.string("retn"): .array([.bool(true), .string("ok")])])
                }
            default: break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            var received: [MsgpackValue] = []
            do {
                for try await item in proxy.stream("storm") { received.append(item) }
                Issue.record("expected the stream to throw")
            } catch let error as TelepathRemoteError {
                #expect(error.kind == .badSyntax)
            }
            #expect(received.count == 1, "items before the exception are delivered")
            // The terminator was clean, so the proxy remains usable.
            #expect(try await proxy.call("other").stringValue == "ok")
            await proxy.close()
        }
    }

    /// After t2:genr there is no resync point on an unframed stream, so anything
    /// other than t2:yield must kill the stream rather than be skipped.
    @Test("an unexpected message during a generator is a protocol violation")
    func generatorProtocolViolation() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn": try await connection.send(Self.handshakeReply())
            case "t2:init":
                try await connection.send("t2:genr", [:])
                try await connection.send("t2:yield", [.string("retn"): .array([.bool(true), .uint(1)])])
                try await connection.send("share:data", [.string("share"): .string("nope")])
            default: break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            do {
                for try await _ in proxy.stream("storm") {}
                Issue.record("expected a protocol violation")
            } catch let error as TelepathError {
                guard case .protocolViolation(let text) = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
                #expect(text.contains("t2:yield"))
            }
            await proxy.close()
        }
    }

    /// A server that dies mid-stream must surface as an error, not a silent
    /// truncation that looks like a completed query.
    @Test("a server closing mid-generator raises rather than ending quietly")
    func serverDiesMidGenerator() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn": try await connection.send(Self.handshakeReply())
            case "t2:init":
                try await connection.send("t2:genr", [:])
                try await connection.send("t2:yield", [.string("retn"): .array([.bool(true), .uint(1)])])
                await connection.close()
            default: break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            var received = 0
            do {
                for try await _ in proxy.stream("storm") { received += 1 }
                Issue.record("expected an error, not a clean end of stream")
            } catch let error as TelepathError {
                #expect(error == .connectionClosed)
            }
            #expect(received == 1)
            await proxy.close()
        }
    }

    @Test("calling a non-generator with stream() is reported clearly")
    func nonGeneratorViaStream() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn": try await connection.send(Self.handshakeReply())
            case "t2:init":
                try await connection.send("t2:fini", [.string("retn"): .array([.bool(true), .string("v")])])
            default: break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            do {
                for try await _ in proxy.stream("getCellInfo") {}
                Issue.record("expected a protocol error")
            } catch let error as TelepathError {
                guard case .protocolViolation(let text) = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
                #expect(text.contains("not a generator"))
            }
            await proxy.close()
        }
    }

    // MARK: - Transport faults

    @Test("garbage on the wire fails the call instead of hanging")
    func malformedStream() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn": try await connection.send(Self.handshakeReply())
            case "t2:init": try await connection.sendRaw([0xc1, 0xc1, 0xc1])  // never valid msgpack
            default: break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            await #expect(throws: (any Error).self) { try await proxy.call("anything") }
            await proxy.close()
        }
    }

    @Test("a server that never replies to the handshake fails the connect")
    func handshakeSilence() async throws {
        try await withDaemon { message, connection in
            if message.name == "tele:syn" { await connection.close() }
        } _: { url in
            await #expect(throws: (any Error).self) { try await Proxy.open(url) }
        }
    }

    /// Values wider than 64 bits ride as ext 0/1 and must survive a real exchange,
    /// not just the codec's unit tests.
    @Test("a big integer survives a round trip through a call")
    func bigIntegerOverTheWire() async throws {
        let magnitude: [UInt8] = [0x01] + [UInt8](repeating: 0, count: 8)   // 2^64
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn": try await connection.send(Self.handshakeReply())
            case "t2:init":
                // Echo the argument straight back.
                let argument = message.todoArgs.first ?? .null
                try await connection.send("t2:fini", [.string("retn"): .array([.bool(true), argument])])
            default: break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            let sent = MsgpackValue.bigInt(sign: .plus, magnitude: magnitude)
            let received = try await proxy.call("echo", [sent])
            #expect(received == sent)
            await proxy.close()
        }
    }

    /// Strings that survived surrogatepass must cross the wire byte-for-byte.
    @Test("a non-UTF8 string survives a round trip through a call")
    func rawStringOverTheWire() async throws {
        try await withDaemon { message, connection in
            switch message.name {
            case "tele:syn": try await connection.send(Self.handshakeReply())
            case "t2:init":
                try await connection.send("t2:fini", [.string("retn"): .array([
                    .bool(true), .rawString([0x61, 0xed, 0xa0, 0x80, 0x62]),
                ])])
            default: break
            }
        } _: { url in
            let proxy = try await Proxy.open(url)
            let value = try await proxy.call("dirty")
            #expect(value.stringBytes == [0x61, 0xed, 0xa0, 0x80, 0x62])
            #expect(value.stringValue == nil, "it must not be silently repaired at the codec layer")
            await proxy.close()
        }
    }
}

/// Captures what the daemon observed, for assertions about what the client sent.
private actor Observed {
    var session: String?
    var method: String?

    func record(session: String?, method: String?) {
        self.session = session
        self.method = method
    }
}
