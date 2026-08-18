import Msgpack

/// Deterministic RNG (SplitMix64) so any failure is reproducible from its seed.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { self.state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public enum FuzzGenerator {
    /// Builds an arbitrary value, weighted toward the cases that actually break
    /// codecs: integer boundaries, non-UTF-8 strings, big integers, nested containers.
    public static func value(using rng: inout SeededRandom, depth: Int = 0) -> MsgpackValue {
        // Bias toward scalars as depth grows so generation terminates.
        let scalarOnly = depth >= 4
        let choice = Int.random(in: 0..<(scalarOnly ? 10 : 13), using: &rng)
        switch choice {
        case 0: return .null
        case 1: return .bool(Bool.random(using: &rng))
        case 2: return .int(boundaryInt(using: &rng))
        case 3: return .uint(boundaryUInt(using: &rng))
        case 4: return .double(boundaryDouble(using: &rng))
        case 5: return .string(randomString(using: &rng))
        case 6: return .rawString(randomInvalidUTF8(using: &rng))
        case 7: return .binary(randomBytes(count: Int.random(in: 0...64, using: &rng), using: &rng))
        case 8: return randomBigInt(using: &rng)
        case 9: return .ext(code: Int8.random(in: 2...127, using: &rng),
                            data: randomBytes(count: Int.random(in: 0...16, using: &rng), using: &rng))
        case 10:
            let count = Int.random(in: 0...6, using: &rng)
            return .array((0..<count).map { _ in value(using: &rng, depth: depth + 1) })
        case 11:
            let count = Int.random(in: 0...6, using: &rng)
            var map: [MsgpackValue: MsgpackValue] = [:]
            for _ in 0..<count {
                // strict_map_key=False: keys are arbitrary values, not just strings.
                map[value(using: &rng, depth: depth + 2)] = value(using: &rng, depth: depth + 1)
            }
            return .map(map)
        default:
            return .array([value(using: &rng, depth: depth + 1)])
        }
    }

    static func boundaryInt(using rng: inout SeededRandom) -> Int64 {
        let boundaries: [Int64] = [0, -1, -32, -33, -128, -129, -32768, -32769,
                                   -2147483648, -2147483649, .min, .max, 127, 128]
        return Bool.random(using: &rng) ? boundaries.randomElement(using: &rng)! : Int64.random(in: .min ... .max, using: &rng)
    }

    static func boundaryUInt(using rng: inout SeededRandom) -> UInt64 {
        let boundaries: [UInt64] = [0, 1, 127, 128, 255, 256, 65535, 65536,
                                    4294967295, 4294967296, .max]
        return Bool.random(using: &rng) ? boundaries.randomElement(using: &rng)! : UInt64.random(in: 0 ... .max, using: &rng)
    }

    static func boundaryDouble(using rng: inout SeededRandom) -> Double {
        let boundaries: [Double] = [0, -0.0, .infinity, -.infinity, .nan,
                                    .leastNonzeroMagnitude, .greatestFiniteMagnitude, 1.5, -1.5]
        return Bool.random(using: &rng) ? boundaries.randomElement(using: &rng)!
                                        : Double(bitPattern: rng.next())
    }

    /// Values wider than 64 bits, matching what ext 0/1 actually carry: a
    /// normalised magnitude of at least 9 bytes with a non-zero leading byte.
    static func randomBigInt(using rng: inout SeededRandom) -> MsgpackValue {
        let count = Int.random(in: 9...48, using: &rng)
        var magnitude = randomBytes(count: count, using: &rng)
        if magnitude[0] == 0 { magnitude[0] = UInt8.random(in: 1...255, using: &rng) }
        return .bigInt(sign: Bool.random(using: &rng) ? .plus : .minus, magnitude: magnitude)
    }

    public static func randomBytes(count: Int, using rng: inout SeededRandom) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }

    static func randomString(using rng: inout SeededRandom) -> String {
        let alphabet = Array("abcXYZ019 \n\t\u{00e9}\u{4e2d}\u{1f600}")
        let count = Int.random(in: 0...40, using: &rng)
        return String((0..<count).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// Byte sequences a Swift String cannot represent, of the kind
    /// `unicode_errors='surrogatepass'` produces.
    static func randomInvalidUTF8(using rng: inout SeededRandom) -> [UInt8] {
        var bytes: [UInt8] = []
        let segments = Int.random(in: 1...4, using: &rng)
        for _ in 0..<segments {
            if Bool.random(using: &rng) {
                // A UTF-8 encoded lone surrogate: ED A0 80 through ED BF BF.
                bytes.append(contentsOf: [0xED,
                                          UInt8.random(in: 0xA0...0xBF, using: &rng),
                                          UInt8.random(in: 0x80...0xBF, using: &rng)])
            } else {
                bytes.append(UInt8.random(in: 0x61...0x7A, using: &rng))
            }
        }
        // Guarantee invalidity, else this belongs in .string.
        if isStrictUTF8Public(bytes) { bytes.append(contentsOf: [0xED, 0xA0, 0x80]) }
        return bytes
    }
}

public enum FuzzFailure: Error, CustomStringConvertible {
    case roundTripMismatch(original: String, decoded: String)
    case byteMismatch(original: String, first: [UInt8], second: [UInt8])
    case decodeCrashRisk(bytes: [UInt8], detail: String)
    case unstableReencode(bytes: [UInt8])

    public var description: String {
        switch self {
        case .roundTripMismatch(let original, let decoded):
            return "round-trip mismatch:\n  original: \(original)\n  decoded:  \(decoded)"
        case .byteMismatch(let original, let first, let second):
            return "re-encode differed for \(original):\n  \(first)\n  \(second)"
        case .decodeCrashRisk(let bytes, let detail):
            return "decoder misbehaved on \(bytes.prefix(32)): \(detail)"
        case .unstableReencode(let bytes):
            return "decode/encode/decode was unstable for \(bytes.prefix(32))"
        }
    }
}

public enum FuzzChecks {
    /// Encode, decode, and require the value to survive. Byte-exactness is required
    /// except where a map's key order makes it unachievable.
    public static func roundTrip(_ value: MsgpackValue) throws {
        let encoded = MsgpackPacker.encode(value)
        let decoded: MsgpackValue
        do {
            decoded = try MsgpackUnpacker.decode(encoded)
        } catch {
            throw FuzzFailure.decodeCrashRisk(bytes: encoded, detail: "\(error)")
        }
        guard semanticallyEqual(value, decoded) else {
            throw FuzzFailure.roundTripMismatch(original: "\(value)", decoded: "\(decoded)")
        }
        let reencoded = MsgpackPacker.encode(decoded)
        if containsMap(value) {
            guard reencoded.count == encoded.count else {
                throw FuzzFailure.byteMismatch(original: "\(value)", first: encoded, second: reencoded)
            }
        } else {
            guard reencoded == encoded else {
                throw FuzzFailure.byteMismatch(original: "\(value)", first: encoded, second: reencoded)
            }
        }
    }

    /// Arbitrary bytes must either decode or throw — never crash, hang, or return
    /// something that re-encodes differently.
    public static func arbitraryBytes(_ bytes: [UInt8]) throws {
        let value: MsgpackValue
        do {
            value = try MsgpackUnpacker.decode(bytes)
        } catch {
            return   // rejecting malformed input is the expected outcome
        }
        let reencoded = MsgpackPacker.encode(value)
        guard let again = try? MsgpackUnpacker.decode(reencoded), semanticallyEqual(value, again) else {
            throw FuzzFailure.unstableReencode(bytes: bytes)
        }
    }

    /// Streaming the same bytes in arbitrary chunks must yield the same values as
    /// decoding them whole — the property the link depends on.
    public static func chunkedStream(_ values: [MsgpackValue], chunkSize: Int) throws {
        let wire = values.flatMap { MsgpackPacker.encode($0) }
        var stream = MsgpackStreamUnpacker()
        var decoded: [MsgpackValue] = []
        for offset in stride(from: 0, to: wire.count, by: max(1, chunkSize)) {
            stream.append(wire[offset..<min(offset + max(1, chunkSize), wire.count)])
            while let value = try stream.next() { decoded.append(value) }
        }
        guard decoded.count == values.count,
              zip(decoded, values).allSatisfy({ semanticallyEqual($0, $1) }) else {
            throw FuzzFailure.roundTripMismatch(original: "\(values.count) values",
                                                decoded: "\(decoded.count) values")
        }
    }

    /// Equality that treats NaN as equal to itself. NaN round-trips bit-exactly, but
    /// Double's Equatable says otherwise, which would report a spurious failure.
    public static func semanticallyEqual(_ a: MsgpackValue, _ b: MsgpackValue) -> Bool {
        switch (a, b) {
        case (.double(let x), .double(let y)):
            return x.bitPattern == y.bitPattern
        case (.array(let x), .array(let y)):
            return x.count == y.count && zip(x, y).allSatisfy(semanticallyEqual)
        case (.map(let x), .map(let y)):
            guard x.count == y.count else { return false }
            var unmatched: [(key: MsgpackValue, value: MsgpackValue)] = []
            for (key, value) in x {
                // Fast path: a normal key finds its partner by hashing.
                if let other = y[key], semanticallyEqual(value, other) { continue }
                unmatched.append((key, value))
            }
            guard !unmatched.isEmpty else { return true }

            // Slow path for keys that hashing cannot match. A `.double(.nan)` key is
            // never equal to itself, so it is unreachable by lookup even though it
            // round-trips byte for byte. Synapse never emits such a key, but msgpack
            // permits it and the fuzzer generates it, so equality must not depend on
            // lookup succeeding.
            var candidates = Array(y)
            for (key, value) in unmatched {
                guard let index = candidates.firstIndex(where: {
                    semanticallyEqual($0.key, key) && semanticallyEqual($0.value, value)
                }) else { return false }
                candidates.remove(at: index)
            }
            return true
        default:
            return a == b
        }
    }

    public static func containsMap(_ value: MsgpackValue) -> Bool {
        switch value {
        case .map: return true
        case .array(let items): return items.contains(where: containsMap)
        default: return false
        }
    }
}
