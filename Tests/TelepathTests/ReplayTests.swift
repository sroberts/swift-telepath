import Foundation
import Msgpack
import Testing
import TelepathTestKit
@testable import Telepath

/// Replays exchanges captured from a live Synapse by tools/capture.py.
///
/// The scripted daemon tests assert what the client does with messages *I* wrote.
/// These assert what it does with bytes a real server actually sent, which is the
/// difference between testing my understanding of the protocol and testing the
/// protocol. The corpus also holds messages this client does not implement yet,
/// so it stays useful as features land.
struct ReplayTests {
    struct Corpus: Decodable {
        let scenarios: [Scenario]
    }

    struct Scenario: Decodable {
        let label: String
        let synapseVersion: String
        let connections: [Connection]
    }

    struct Connection: Decodable {
        let index: Int
        let messages: [Recorded]
    }

    struct Recorded: Decodable {
        let direction: String   // "c2s" or "s2c"
        let name: String?
        let hex: String
    }

    static let corpus: Corpus = {
        let url = Bundle.module.url(forResource: "protocol-vectors", withExtension: "json")!
        return try! JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }()

    static func scenario(_ label: String) -> Scenario {
        corpus.scenarios.first { $0.label == label }!
    }

    // MARK: - Structural conformance

    @Test("the corpus covers the scenarios spec.md 6.2 calls for")
    func corpusCoverage() {
        let labels = Set(Self.corpus.scenarios.map(\.label))
        for required in ["unary-call", "unary-exception", "storm-generator",
                         "early-abandonment", "auth-failure", "dynamic-share"] {
            #expect(labels.contains(required), "missing captured scenario: \(required)")
        }
        #expect(Self.corpus.scenarios.allSatisfy { $0.synapseVersion == "2.249.0" })
    }

    /// Every byte a real server sent must decode. A failure here means the codec
    /// cannot read production traffic, whatever the synthetic vectors say.
    @Test("every recorded message decodes as a Telepath message",
          arguments: ReplayTests.corpus.scenarios)
    func recordedMessagesDecode(scenario: Scenario) throws {
        for connection in scenario.connections {
            for recorded in connection.messages {
                let bytes = try #require(hexToBytes(recorded.hex))
                let value = try MsgpackUnpacker.decode(bytes)
                let message = try Message(value)
                #expect(message.name == recorded.name)
                // Re-encoding must produce the same length; map ordering may differ.
                #expect(MsgpackPacker.encode(value).count == bytes.count)
            }
        }
    }

    /// A real handshake reply must populate the fields the client depends on.
    @Test("a captured handshake parses into session, features and method metadata")
    func handshakeParses() throws {
        let scenario = Self.scenario("unary-call")
        let reply = try #require(scenario.connections
            .flatMap(\.messages)
            .first { $0.direction == "s2c" && $0.name == "tele:syn" })

        let message = try Message(try MsgpackUnpacker.decode(try #require(hexToBytes(reply.hex))))
        #expect(message["vers"]?[0]?.intValue == 3)
        #expect(message["sess"]?.stringValue?.count == 32)

        let shareInfo = ShareInfo(try #require(message["sharinfo"]))
        #expect(shareInfo.synapseVersion == [2, 249, 0])
        #expect(shareInfo.methods["storm"]?.isGenerator == true)
        #expect(shareInfo.methods["callStorm"]?.isGenerator == false)
    }

    /// The failure arm of a real retn tuple, with the fields Synapse actually sends.
    @Test("a captured remote exception parses with its name and message")
    func remoteExceptionParses() throws {
        let scenario = Self.scenario("unary-exception")
        let fini = try #require(scenario.connections
            .flatMap(\.messages)
            .first { $0.direction == "s2c" && $0.name == "t2:fini" })

        let message = try Message(try MsgpackUnpacker.decode(try #require(hexToBytes(fini.hex))))
        let retn = try #require(message["retn"])
        do {
            _ = try Retn.unwrap(retn)
            Issue.record("expected the captured retn to carry a failure")
        } catch let error as TelepathRemoteError {
            #expect(error.kind == .noSuchMeth)
            #expect(error.mesg?.isEmpty == false)
        }
    }

    /// t2:share is unimplemented, so this pins what a real one looks like for
    /// whoever implements it — and proves the client's rejection is based on a
    /// correctly parsed message rather than a parse failure.
    @Test("a captured dynamic share carries an iden and share info")
    func dynamicShareParses() throws {
        let scenario = Self.scenario("dynamic-share")
        let share = try #require(scenario.connections
            .flatMap(\.messages)
            .first { $0.direction == "s2c" && $0.name == "t2:share" })

        let message = try Message(try MsgpackUnpacker.decode(try #require(hexToBytes(share.hex))))
        let iden = try #require(message["iden"]?.stringValue)
        #expect(iden.count == 32, "a share iden is a 32-char hex guid")
        #expect(message["sharinfo"] != nil)
    }

    /// What the client sends must match what a real server accepted, or the
    /// captures would not have produced successful replies.
    @Test("captured client messages have the shape Synapse accepted")
    func clientMessagesMatchCapture() throws {
        let scenario = Self.scenario("unary-call")
        let sent = scenario.connections.flatMap(\.messages).filter { $0.direction == "c2s" }

        let handshakeRecord = try #require(sent.first { $0.name == "tele:syn" })
        let handshakeBytes = try #require(hexToBytes(handshakeRecord.hex))
        let handshake = try Message(try MsgpackUnpacker.decode(handshakeBytes))
        #expect(handshake["vers"] == .array([.uint(3), .uint(0)]))
        #expect(handshake["name"]?.stringValue == "*")

        let taskInitRecord = try #require(sent.first { $0.name == "t2:init" })
        let taskInitBytes = try #require(hexToBytes(taskInitRecord.hex))
        let taskInit = try Message(try MsgpackUnpacker.decode(taskInitBytes))
        // A pool link carries the session iden; it is the only thing binding it to
        // an authenticated session.
        #expect(taskInit["sess"]?.stringValue?.count == 32)
        #expect(taskInit["todo"]?[0]?.stringValue == "getCellInfo")
        #expect(taskInit["name"]?.isNull == true)
    }

    // MARK: - Full replay

    /// Drives the client using only bytes a real server sent. If the client can
    /// complete a call against a recording, its parsing matches production.
    @Test("a unary call completes against replayed server bytes")
    func replayUnaryCall() async throws {
        let replay = Replayer(scenario: Self.scenario("unary-call"))
        let daemon = try await FakeDaemon.start { message, connection in
            try await replay.respond(to: message, on: connection)
        }
        defer { Task { await daemon.stop() } }

        let proxy = try await Proxy.open(daemon.url)
        let info = try await proxy.call("getCellInfo")
        #expect(info["cell"] != nil, "the replayed reply should carry cell info")
        #expect(info["synapse"]?["version"] != nil)
        await proxy.close()
    }

    @Test("a storm generator completes against replayed server bytes")
    func replayGenerator() async throws {
        let replay = Replayer(scenario: Self.scenario("storm-generator"))
        let daemon = try await FakeDaemon.start { message, connection in
            try await replay.respond(to: message, on: connection)
        }
        defer { Task { await daemon.stop() } }

        let proxy = try await Proxy.open(daemon.url)
        var kinds: [String] = []
        for try await item in proxy.stream("storm", [.string("[ inet:ipv4=1.2.3.4 ]")]) {
            if let kind = item[0]?.stringValue { kinds.append(kind) }
        }
        #expect(kinds.first == "init")
        #expect(kinds.last == "fini")
        await proxy.close()
    }

    @Test("a rejected handshake replays as AuthDeny")
    func replayAuthFailure() async throws {
        let replay = Replayer(scenario: Self.scenario("auth-failure"))
        let daemon = try await FakeDaemon.start { message, connection in
            try await replay.respond(to: message, on: connection)
        }
        defer { Task { await daemon.stop() } }

        do {
            _ = try await Proxy.open(daemon.url)
            Issue.record("expected the replayed handshake to fail")
        } catch let error as TelepathRemoteError {
            #expect(error.kind == .authDeny)
        }
    }
}

/// Replays a captured scenario: each new connection takes the next recorded
/// connection, and every inbound message releases the server messages that
/// followed it in the recording.
private actor Replayer {
    private let connections: [[ReplayTests.Recorded]]
    private var nextConnection = 0
    private var cursors: [ObjectIdentifier: (script: Int, position: Int)] = [:]

    init(scenario: ReplayTests.Scenario) {
        self.connections = scenario.connections
            .sorted { $0.index < $1.index }
            .map(\.messages)
    }

    func respond(to message: FakeDaemon.Message, on connection: FakeDaemon.Connection) async throws {
        let key = ObjectIdentifier(connection)
        var cursor = cursors[key] ?? {
            let assigned = (script: nextConnection, position: 0)
            nextConnection += 1
            return assigned
        }()
        guard cursor.script < connections.count else { return }
        let script = connections[cursor.script]

        // Skip past the client message this responds to.
        while cursor.position < script.count, script[cursor.position].direction == "c2s" {
            cursor.position += 1
        }
        // Emit every server message queued behind it.
        while cursor.position < script.count, script[cursor.position].direction == "s2c" {
            if let bytes = hexToBytes(script[cursor.position].hex) {
                try await connection.sendRaw(bytes)
            }
            cursor.position += 1
        }
        cursors[key] = cursor
    }
}

func hexToBytes(_ hex: String) -> [UInt8]? {
    guard hex.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        out.append(byte)
        index = next
    }
    return out
}

extension ReplayTests.Scenario: CustomTestStringConvertible {
    var testDescription: String { label }
}
