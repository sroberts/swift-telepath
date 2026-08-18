/// Decodes `Decodable` types from ``MsgpackValue``.
///
/// This is what makes a typed service layer worth using: `getCellInfo` becomes a
/// struct rather than a pile of subscripts.
public struct MsgpackDecoder: Sendable {
    /// How to handle a ``MsgpackValue/rawString(_:)`` reaching a `String` property.
    ///
    /// Synapse packs with `surrogatepass`, so intelligence data legitimately contains
    /// strings Swift cannot represent. Defaulting to `.replaceInvalid` means a query
    /// finishes rather than failing on one dirty property; callers who need the exact
    /// bytes take `[UInt8]` or ``MsgpackValue`` in that position instead.
    public enum StringDecodingStrategy: Sendable {
        case replaceInvalid
        case `throw`
    }

    public var stringDecodingStrategy: StringDecodingStrategy = .replaceInvalid

    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from value: MsgpackValue) throws -> T {
        let decoder = _MsgpackDecoder(value: value, codingPath: [], strategy: stringDecodingStrategy)
        return try T(from: decoder)
    }

    public func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try decode(type, from: MsgpackUnpacker.decode(bytes))
    }
}

private struct _MsgpackDecoder: Decoder {
    let value: MsgpackValue
    let codingPath: [any CodingKey]
    let strategy: MsgpackDecoder.StringDecodingStrategy
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .map(let entries) = value else {
            throw MsgpackError.typeMismatch(expected: "map", actual: kind(value), path: pathString(codingPath))
        }
        return KeyedDecodingContainer(_KeyedContainer(entries: entries, codingPath: codingPath, strategy: strategy))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let items) = value else {
            throw MsgpackError.typeMismatch(expected: "array", actual: kind(value), path: pathString(codingPath))
        }
        return _UnkeyedContainer(items: items, codingPath: codingPath, strategy: strategy)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        _SingleValueContainer(value: value, codingPath: codingPath, strategy: strategy)
    }
}

private struct _KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let entries: [MsgpackValue: MsgpackValue]
    let codingPath: [any CodingKey]
    let strategy: MsgpackDecoder.StringDecodingStrategy

    var allKeys: [Key] { entries.keys.compactMap { $0.stringValue.flatMap(Key.init(stringValue:)) } }

    func contains(_ key: Key) -> Bool { entries[.string(key.stringValue)] != nil }

    private func child(_ key: Key) throws -> _MsgpackDecoder {
        guard let value = entries[.string(key.stringValue)] else {
            throw MsgpackError.keyNotFound(key.stringValue, path: pathString(codingPath))
        }
        return _MsgpackDecoder(value: value, codingPath: codingPath + [key], strategy: strategy)
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        entries[.string(key.stringValue)]?.isNull ?? true
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try T(from: try child(key))
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try child(key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try child(key).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        _MsgpackDecoder(value: .map(entries), codingPath: codingPath, strategy: strategy)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder { try child(key) }
}

private struct _UnkeyedContainer: UnkeyedDecodingContainer {
    let items: [MsgpackValue]
    let codingPath: [any CodingKey]
    let strategy: MsgpackDecoder.StringDecodingStrategy
    var currentIndex = 0

    var count: Int? { items.count }
    var isAtEnd: Bool { currentIndex >= items.count }

    private mutating func advance() throws -> _MsgpackDecoder {
        guard !isAtEnd else {
            throw MsgpackError.valueNotFound("element \(currentIndex)", path: pathString(codingPath))
        }
        defer { currentIndex += 1 }
        return _MsgpackDecoder(value: items[currentIndex],
                               codingPath: codingPath + [IndexKey(currentIndex)],
                               strategy: strategy)
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { return true }
        if items[currentIndex].isNull {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: try advance())
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try advance().container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try advance().unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder { try advance() }
}

private struct _SingleValueContainer: SingleValueDecodingContainer {
    let value: MsgpackValue
    let codingPath: [any CodingKey]
    let strategy: MsgpackDecoder.StringDecodingStrategy

    func decodeNil() -> Bool { value.isNull }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard let b = value.boolValue else { throw mismatch("bool") }
        return b
    }

    func decode(_ type: String.Type) throws -> String {
        switch value {
        case .string(let s):
            return s
        case .rawString(let bytes):
            // surrogatepass output: either salvage it lossily or refuse, per policy.
            switch strategy {
            case .replaceInvalid: return String(decoding: bytes, as: UTF8.self)
            case .throw: throw MsgpackError.invalidUTF8(path: pathString(codingPath))
            }
        default:
            throw mismatch("string")
        }
    }

    func decode(_ type: Double.Type) throws -> Double {
        guard let d = value.doubleValue else { throw mismatch("double") }
        return d
    }

    func decode(_ type: Float.Type) throws -> Float { Float(try decode(Double.self)) }

    /// The protocol requires concrete overloads; they all funnel here.
    private func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        switch value {
        case .int(let i):
            guard let narrowed = T(exactly: i) else { throw MsgpackError.integerOverflow("\(i) as \(T.self)") }
            return narrowed
        case .uint(let u):
            guard let narrowed = T(exactly: u) else { throw MsgpackError.integerOverflow("\(u) as \(T.self)") }
            return narrowed
        case .double(let d):
            guard let narrowed = T(exactly: d.rounded(.towardZero)) else {
                throw MsgpackError.integerOverflow("\(d) as \(T.self)")
            }
            return narrowed
        case .bigInt:
            throw MsgpackError.integerOverflow("big integer does not fit \(T.self)")
        default:
            throw mismatch("integer")
        }
    }

    func decode(_ type: Int.Type) throws -> Int { try integer(Int.self) }
    func decode(_ type: Int8.Type) throws -> Int8 { try integer(Int8.self) }
    func decode(_ type: Int16.Type) throws -> Int16 { try integer(Int16.self) }
    func decode(_ type: Int32.Type) throws -> Int32 { try integer(Int32.self) }
    func decode(_ type: Int64.Type) throws -> Int64 { try integer(Int64.self) }
    func decode(_ type: UInt.Type) throws -> UInt { try integer(UInt.self) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(UInt8.self) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(UInt16.self) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(UInt32.self) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(UInt64.self) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        // MsgpackValue decodes to itself, so callers can keep dirty data verbatim.
        if T.self == MsgpackValue.self { return value as! T }
        if T.self == [UInt8].self, let bytes = value.binaryValue ?? value.stringBytes { return bytes as! T }
        return try T(from: _MsgpackDecoder(value: value, codingPath: codingPath, strategy: strategy))
    }

    private func mismatch(_ expected: String) -> MsgpackError {
        .typeMismatch(expected: expected, actual: kind(value), path: pathString(codingPath))
    }
}

/// Lets ``MsgpackValue`` appear directly in a Decodable model, so a caller can keep
/// an arbitrary subtree — or a value with dirty strings — without pre-declaring its
/// shape.
extension MsgpackValue: Decodable {
    public init(from decoder: any Decoder) throws {
        guard let decoder = decoder as? _MsgpackDecoder else {
            throw MsgpackError.unsupported("MsgpackValue requires MsgpackDecoder")
        }
        self = decoder.value
    }
}

private struct IndexKey: CodingKey {
    let index: Int
    init(_ index: Int) { self.index = index }
    var stringValue: String { "\(index)" }
    var intValue: Int? { index }
    init?(stringValue: String) { guard let i = Int(stringValue) else { return nil }; index = i }
    init?(intValue: Int) { index = intValue }
}

private func pathString(_ path: [any CodingKey]) -> String {
    path.isEmpty ? "<root>" : path.map(\.stringValue).joined(separator: ".")
}

private func kind(_ value: MsgpackValue) -> String {
    switch value {
    case .null: return "null"
    case .bool: return "bool"
    case .int, .uint: return "integer"
    case .bigInt: return "big integer"
    case .double: return "double"
    case .string: return "string"
    case .rawString: return "non-UTF8 string"
    case .binary: return "binary"
    case .array: return "array"
    case .map: return "map"
    case .ext: return "ext"
    }
}
