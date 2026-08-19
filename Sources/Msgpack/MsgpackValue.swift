/// A msgpack value as produced by Synapse's packer configuration.
///
/// Two cases exist only because Synapse's Python packer deviates from stock
/// msgpack, and both are load-bearing rather than defensive:
///
/// - ``rawString(_:)`` holds a msgpack `str` whose bytes are not valid UTF-8.
///   Synapse encodes with `unicode_errors='surrogatepass'`, so real Cortex data
///   contains lone surrogates that Swift's `String` cannot represent. Failing the
///   whole message over one dirty property would make this library unusable.
/// - ``bigInt(sign:magnitude:)`` holds an integer too wide for 64 bits, carried on
///   the wire as ext type 0 (unsigned) or ext type 1 (signed). It is kept distinct
///   from ``ext(code:data:)`` so that encoding is unambiguous and an *unknown* ext
///   code still surfaces as a clean protocol error instead of a decode crash.
public enum MsgpackValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    /// Integer outside the 64-bit range. `magnitude` is big-endian, most significant
    /// byte first, with leading zero bytes stripped.
    case bigInt(sign: Sign, magnitude: [UInt8])
    case double(Double)
    case string(String)
    /// A valid msgpack `str` that is not valid UTF-8. Round-trips byte for byte.
    case rawString([UInt8])
    case binary([UInt8])
    case array([MsgpackValue])
    case map([MsgpackValue: MsgpackValue])
    /// An ext type other than 0 or 1. Decoding one is a protocol error at the
    /// Telepath layer, but the codec preserves it so the error can say what it saw.
    case ext(code: Int8, data: [UInt8])

    public enum Sign: Hashable, Sendable {
        case plus, minus
    }
}

// MARK: - Equality

/// Integers compare by numeric value, not by which case carries them.
///
/// msgpack draws no wire distinction between a signed and an unsigned integer, so
/// `.int(0)` encodes to the same byte as `.uint(0)` and decodes back as whichever
/// case the format byte implies. Case-sensitive equality would make a decoded value
/// unequal to the value that produced it — `MsgpackValue.int(5) != .uint(5)` — which
/// is a trap for anyone asserting on a result. ``bigInt`` participates too, so an
/// integer is equal to itself however wide it arrived.
extension MsgpackValue: Hashable {
    /// One shape every integer case can be compared and hashed in.
    ///
    /// Decoding hashes every map key, so the common cases must not allocate:
    /// ``narrow`` covers everything representable in 64 bits, which is every
    /// integer Synapse sends outside the ext types.
    enum IntegerCanonical: Hashable {
        case narrow(negative: Bool, magnitude: UInt64)
        case wide(negative: Bool, magnitude: [UInt8])
    }

    var integerCanonical: IntegerCanonical? {
        switch self {
        case .int(let value):
            return .narrow(negative: value < 0, magnitude: value.magnitude)
        case .uint(let value):
            return .narrow(negative: false, magnitude: value)
        case .bigInt(let sign, let magnitude):
            let stripped = BigIntBytes.stripLeadingZeros(magnitude)
            // Zero has no sign, so -0 must not differ from 0.
            let negative = sign == .minus && !stripped.isEmpty
            // A big integer that fits in 64 bits is the same number as a narrow one
            // and has to compare and hash identically.
            guard stripped.count > 8 else {
                var value: UInt64 = 0
                for byte in stripped { value = (value << 8) | UInt64(byte) }
                return .narrow(negative: negative, magnitude: value)
            }
            return .wide(negative: negative, magnitude: stripped)
        default:
            return nil
        }
    }

    public static func == (lhs: MsgpackValue, rhs: MsgpackValue) -> Bool {
        switch (lhs, rhs) {
        // Fast paths first: these dominate, and they allocate nothing.
        case (.int(let a), .int(let b)): return a == b
        case (.uint(let a), .uint(let b)): return a == b
        case (.int(let a), .uint(let b)), (.uint(let b), .int(let a)):
            return a >= 0 && UInt64(a) == b

        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.rawString(let a), .rawString(let b)): return a == b
        case (.binary(let a), .binary(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.map(let a), .map(let b)): return a == b
        case (.ext(let a, let x), .ext(let b, let y)): return a == b && x == y

        default:
            // Anything involving .bigInt, where a width conversion may be needed.
            guard let left = lhs.integerCanonical, let right = rhs.integerCanonical else {
                return false
            }
            return left == right
        }
    }

    public func hash(into hasher: inout Hasher) {
        // Equal values must hash equally, so every integer case hashes its canonical
        // numeric form rather than its case.
        if let canonical = integerCanonical {
            hasher.combine(0 as UInt8)
            hasher.combine(canonical)
            return
        }
        switch self {
        case .null: hasher.combine(1 as UInt8)
        case .bool(let value): hasher.combine(2 as UInt8); hasher.combine(value)
        case .double(let value): hasher.combine(3 as UInt8); hasher.combine(value)
        case .string(let value): hasher.combine(4 as UInt8); hasher.combine(value)
        case .rawString(let value): hasher.combine(5 as UInt8); hasher.combine(value)
        case .binary(let value): hasher.combine(6 as UInt8); hasher.combine(value)
        case .array(let value): hasher.combine(7 as UInt8); hasher.combine(value)
        case .map(let value): hasher.combine(8 as UInt8); hasher.combine(value)
        case .ext(let code, let data): hasher.combine(9 as UInt8); hasher.combine(code); hasher.combine(data)
        case .int, .uint, .bigInt: break   // handled above
        }
    }
}

// MARK: - Convenience accessors

extension MsgpackValue {
    /// Sugar for the overwhelmingly common string-keyed map access.
    ///
    /// Map keys are modelled as full values because Synapse packs with
    /// `strict_map_key=False` and genuinely uses integer and tuple keys.
    public subscript(key: String) -> MsgpackValue? {
        guard case .map(let m) = self else { return nil }
        return m[.string(key)]
    }

    public subscript(index: Int) -> MsgpackValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var boolValue: Bool? {
        guard case .bool(let b) = self else { return nil }
        return b
    }

    /// Narrows either integer case to `Int64`, returning nil when the value does not
    /// fit. Big integers always return nil; reach for ``MsgpackValue/bigInt(sign:magnitude:)``
    /// explicitly there.
    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .uint(let u): return u <= UInt64(Int64.max) ? Int64(u) : nil
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .uint(let u): return Double(u)
        default: return nil
        }
    }

    /// The decoded text of a `str`. Nil for ``rawString(_:)`` — use
    /// ``stringBytes`` when the caller can handle non-UTF-8 data.
    public var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }

    /// The raw bytes of a msgpack `str`, whether or not it decoded as UTF-8.
    public var stringBytes: [UInt8]? {
        switch self {
        case .string(let s): return Array(s.utf8)
        case .rawString(let b): return b
        default: return nil
        }
    }

    public var binaryValue: [UInt8]? {
        guard case .binary(let b) = self else { return nil }
        return b
    }

    public var arrayValue: [MsgpackValue]? {
        guard case .array(let a) = self else { return nil }
        return a
    }

    public var mapValue: [MsgpackValue: MsgpackValue]? {
        guard case .map(let m) = self else { return nil }
        return m
    }
}

// MARK: - Literal ergonomics

extension MsgpackValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension MsgpackValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension MsgpackValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension MsgpackValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension MsgpackValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension MsgpackValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: MsgpackValue...) { self = .array(elements) }
}

extension MsgpackValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (MsgpackValue, MsgpackValue)...) {
        self = .map(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension MsgpackValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return String(b)
        case .int(let i): return String(i)
        case .uint(let u): return String(u)
        case .bigInt(let sign, let mag):
            return (sign == .minus ? "-0x" : "0x") + hexEncode(mag)
        case .double(let d): return String(d)
        case .string(let s): return "\"\(s)\""
        case .rawString(let b): return "raw\"\(hexEncode(b))\""
        case .binary(let b): return "bin(\(b.count) bytes)"
        case .array(let a): return "[" + a.map(\.description).joined(separator: ", ") + "]"
        case .map(let m): return "{" + m.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "}"
        case .ext(let code, let data): return "ext(\(code), \(data.count) bytes)"
        }
    }
}

/// Local hex formatter: the Msgpack target stays free of Foundation so it remains
/// trivially extractable and portable.
func hexEncode(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef")
    var out = ""
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 0x0f)])
    }
    return out
}
