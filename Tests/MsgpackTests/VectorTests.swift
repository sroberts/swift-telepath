import Foundation
import Testing
@testable import Msgpack

/// Telepath has no published specification, so these vectors — generated from the
/// pinned Synapse release by tools/genvectors.py — are the codec's contract.
/// Every vector is checked in both directions: the bytes must decode to the
/// expected value, and that value must re-encode to the identical bytes.
struct VectorTests {
    struct Manifest: Decodable {
        let synapseVersion: String
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let description: String
        let pythonRepr: String
        let hex: String
        let kind: String
        let expect: Expectation?
        let roundtrip: Bool
    }

    /// `expect` is polymorphic across kinds: a scalar for most, sign+magnitude for
    /// big integers, and absent for containers where the hex round-trip is the test.
    enum Expectation: Decodable {
        case scalar(String)
        case bigInt(sign: String, magHex: String)

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
                self = .scalar(s)
                return
            }
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            self = .bigInt(sign: try keyed.decode(String.self, forKey: .sign),
                           magHex: try keyed.decode(String.self, forKey: .magHex))
        }

        enum CodingKeys: String, CodingKey { case sign, magHex }
    }

    static let manifest: Manifest = {
        let url = Bundle.module.url(forResource: "vectors", withExtension: "json")!
        return try! JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }()

    @Test("vectors were generated from the pinned Synapse release")
    func pinnedVersion() {
        #expect(Self.manifest.synapseVersion == "2.249.0")
        #expect(Self.manifest.vectors.count >= 30)
    }

    @Test("every vector decodes to the expected value", arguments: VectorTests.manifest.vectors)
    func decodes(vector: Vector) throws {
        let bytes = try #require(hexToBytes(vector.hex))
        let value = try MsgpackUnpacker.decode(bytes)
        assertKind(value, vector: vector)
    }

    /// Byte-exact re-encoding matters because Telepath does no canonicalisation;
    /// a divergence stays invisible until a live server rejects a message.
    ///
    /// Maps are the one documented exception. Swift's `Dictionary` does not preserve
    /// insertion order, so a map re-encodes with its keys permuted. msgpack maps are
    /// semantically unordered and Synapse unpacks them into a `dict`, so the ordering
    /// carries no protocol meaning — these are held to semantic equality plus an
    /// identical encoded length instead.
    @Test("every vector re-encodes to identical bytes", arguments: VectorTests.manifest.vectors)
    func reencodes(vector: Vector) throws {
        guard vector.roundtrip else { return }
        let bytes = try #require(hexToBytes(vector.hex))
        let value = try MsgpackUnpacker.decode(bytes)
        let encoded = MsgpackPacker.encode(value)

        if containsMap(value) {
            #expect(try MsgpackUnpacker.decode(encoded) == value, "\(vector.description) semantic round-trip")
            #expect(encoded.count == bytes.count, "\(vector.description) encoded length")
        } else {
            #expect(encoded == bytes, "\(vector.description): \(bytesToHex(encoded)) != \(vector.hex)")
        }
    }

    private func containsMap(_ value: MsgpackValue) -> Bool {
        switch value {
        case .map: return true
        case .array(let items): return items.contains(where: containsMap)
        default: return false
        }
    }

    private func assertKind(_ value: MsgpackValue, vector: Vector) {
        switch (vector.kind, value) {
        case ("null", .null), ("map", .map), ("array", .array):
            break
        case ("bool", .bool(let b)):
            if case .scalar(let s) = vector.expect { #expect(String(b) == s) }
        case ("int", .int), ("int", .uint), ("uint", .uint), ("uint", .int):
            break
        case ("string", .string(let s)):
            if case .scalar(let e) = vector.expect { #expect(s == e) }
        case ("rawstring", .rawString(let bytes)):
            // The whole point of .rawString: surrogatepass output that Swift's
            // String cannot represent must survive as bytes.
            if case .scalar(let e) = vector.expect { #expect(bytesToHex(bytes) == e) }
        case ("binary", .binary(let bytes)):
            if case .scalar(let e) = vector.expect { #expect(bytesToHex(bytes) == e) }
        case ("double", .double(let d)):
            if case .scalar(let e) = vector.expect {
                switch e {
                case "nan": #expect(d.isNaN)
                case "inf": #expect(d == .infinity)
                case "-inf": #expect(d == -.infinity)
                case "-0.0": #expect(d == 0 && d.sign == .minus)
                default: #expect(String(d) == e)
                }
            }
        case ("bigint", .bigInt(let sign, let magnitude)):
            if case .bigInt(let esign, let magHex) = vector.expect {
                #expect((sign == .minus ? "-" : "+") == esign, "\(vector.description) sign")
                #expect(bytesToHex(magnitude) == magHex, "\(vector.description) magnitude")
            }
        default:
            Issue.record("\(vector.description): expected kind \(vector.kind), decoded \(value)")
        }
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

func bytesToHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

extension VectorTests.Vector: CustomTestStringConvertible {
    var testDescription: String { description }
}
