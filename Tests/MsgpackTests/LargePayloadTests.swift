import Foundation
import Testing
@testable import Msgpack

/// Conformance for payloads too large to store as hex. The manifest records the
/// length and a checksum of the bytes Synapse produced; these rebuild the same
/// value and compare.
struct LargePayloadTests {
    struct DigestVector: Decodable {
        let description: String
        let kind: String
        let detail: String?
        let byteLength: Int
        let headerHex: String
        let fnv1a64: String
    }

    struct Manifest: Decodable {
        let digestVectors: [DigestVector]
    }

    static let vectors: [DigestVector] = {
        let url = Bundle.module.url(forResource: "vectors", withExtension: "json")!
        return try! JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)).digestVectors
    }()

    /// Rebuilds the value the Python generator packed, from its recorded recipe.
    private func value(for vector: DigestVector) -> MsgpackValue? {
        switch vector.description {
        case "20 MiB binary blob":
            return .binary((0..<(20 * 1024 * 1024)).map { UInt8($0 % 251) })
        case "1 MiB ascii string":
            return .string(String(repeating: "z", count: 1024 * 1024))
        case "100k element integer array":
            return .array((0..<100_000).map { .uint(UInt64($0)) })
        case "10k entry map":
            var map: [MsgpackValue: MsgpackValue] = [:]
            for i in 0..<10_000 { map[.string("key\(i)")] = .uint(UInt64(i)) }
            return .map(map)
        default:
            return nil
        }
    }

    @Test("large payloads pack to the same bytes Synapse produced",
          arguments: LargePayloadTests.vectors)
    func packsIdentically(vector: DigestVector) throws {
        let value = try #require(self.value(for: vector), "no recipe for \(vector.description)")
        let packed = MsgpackPacker.encode(value)

        #expect(packed.count == vector.byteLength, "\(vector.description) length")

        // Map key order is not preserved by Swift's Dictionary, so a map's bytes
        // legitimately differ past the container header. Length plus the header
        // still pin the format widths, which is what conformance turns on here.
        if vector.kind == "map" {
            #expect(bytesToHex(Array(packed.prefix(3))) == String(vector.headerHex.prefix(6)),
                    "\(vector.description) container header")
        } else {
            #expect(bytesToHex(Array(packed.prefix(8))) == vector.headerHex, "\(vector.description) header")
            #expect(String(fnv1a64(packed)) == vector.fnv1a64, "\(vector.description) digest")
        }
    }

    @Test("large payloads round-trip through the decoder",
          arguments: LargePayloadTests.vectors)
    func roundTrips(vector: DigestVector) throws {
        let value = try #require(self.value(for: vector))
        let decoded = try MsgpackUnpacker.decode(MsgpackPacker.encode(value))
        #expect(decoded == value)
    }

    /// The 20 MiB case is the one that matters for the link: it must arrive intact
    /// when delivered in small chunks, as it will be off a socket.
    @Test("a 20 MiB payload reassembles from small chunks")
    func chunkedDelivery() throws {
        let value = MsgpackValue.binary((0..<(20 * 1024 * 1024)).map { UInt8($0 % 251) })
        let wire = MsgpackPacker.encode(value)

        var stream = MsgpackStreamUnpacker()
        var decoded: MsgpackValue?
        // 16 KiB is a realistic socket read size.
        for offset in stride(from: 0, to: wire.count, by: 16 * 1024) {
            stream.append(wire[offset..<min(offset + 16 * 1024, wire.count)])
            if let next = try stream.next() { decoded = next }
        }
        #expect(decoded == value)
    }
}

/// FNV-1a, matching tools/genvectors.py so digests are comparable across languages.
func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}

extension LargePayloadTests.DigestVector: CustomTestStringConvertible {
    var testDescription: String { description }
}
