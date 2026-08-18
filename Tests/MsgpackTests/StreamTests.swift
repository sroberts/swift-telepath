import Testing
@testable import Msgpack

/// The Telepath link is an unframed msgpack stream: there is no length prefix to
/// seek to, so the unpacker must tolerate a value being split across any byte
/// boundary and must emit values the instant they complete.
struct StreamTests {
    private let messages: [MsgpackValue] = [
        .array([.string("tele:syn"), .map([.string("vers"): .array([.uint(3), .uint(0)])])]),
        .array([.string("t2:yield"), .map([.string("retn"): .array([.bool(true), .string("node")])])]),
        .array([.string("t2:fini"), .map([.string("retn"): .null])]),
    ]

    @Test("values are emitted as they complete when fed one byte at a time")
    func bytewise() throws {
        let wire = messages.flatMap { MsgpackPacker.encode($0) }
        var stream = MsgpackStreamUnpacker()
        var decoded: [MsgpackValue] = []

        for byte in wire {
            stream.append([byte])
            while let value = try stream.next() { decoded.append(value) }
        }

        #expect(decoded == messages)
    }

    @Test("a single chunk containing several messages yields all of them")
    func batched() throws {
        var stream = MsgpackStreamUnpacker()
        stream.append(messages.flatMap { MsgpackPacker.encode($0) })

        var decoded: [MsgpackValue] = []
        while let value = try stream.next() { decoded.append(value) }
        #expect(decoded == messages)
    }

    @Test("a truncated trailing value is retained, not lost or thrown")
    func partialTail() throws {
        var wire = MsgpackPacker.encode(messages[0])
        let complete = wire.count
        wire.append(contentsOf: MsgpackPacker.encode(messages[1]).prefix(3))

        var stream = MsgpackStreamUnpacker()
        stream.append(wire)

        #expect(try stream.next() == messages[0])
        #expect(try stream.next() == nil)
        #expect(stream.pendingByteCount == wire.count - complete)

        // The remainder arrives and the held bytes complete the value.
        stream.append(MsgpackPacker.encode(messages[1]).dropFirst(3))
        #expect(try stream.next() == messages[1])
    }

    @Test("chunk boundaries inside a large binary payload are handled")
    func largePayload() throws {
        let blob = MsgpackValue.binary([UInt8](repeating: 0xab, count: 1 << 20))
        let wire = MsgpackPacker.encode(blob)
        var stream = MsgpackStreamUnpacker()

        for chunk in stride(from: 0, to: wire.count, by: 4096) {
            stream.append(wire[chunk..<min(chunk + 4096, wire.count)])
            if chunk + 4096 < wire.count { #expect(try stream.next() == nil) }
        }
        #expect(try stream.next() == blob)
    }

    @Test("a malformed format byte throws rather than silently resyncing")
    func malformed() throws {
        var stream = MsgpackStreamUnpacker()
        stream.append([0xc1])   // never a valid msgpack format byte
        #expect(throws: MsgpackError.self) { try stream.next() }
    }
}
