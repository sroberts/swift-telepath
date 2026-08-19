/// Encodes `Encodable` values to ``MsgpackValue``.
///
/// The counterpart to ``MsgpackDecoder``: it lets a caller pass Swift types as
/// call arguments instead of hand-building maps and arrays.
public struct MsgpackEncoder: Sendable {
    /// How to encode a `String` that is not representable on the wire.
    ///
    /// Swift strings are always valid UTF-8, so this only matters for the reverse
    /// direction; the option exists so the type reads symmetrically with the
    /// decoder and leaves room for a stricter mode later.
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> MsgpackValue {
        // MsgpackValue passes through, so a caller can mix typed models with raw
        // subtrees — including dirty strings that no Encodable model could carry.
        if let value = value as? MsgpackValue { return value }
        let encoder = _MsgpackEncoder(codingPath: [])
        try value.encode(to: encoder)
        return encoder.resolved
    }

    public func encodeToBytes<T: Encodable>(_ value: T) throws -> [UInt8] {
        MsgpackPacker.encode(try encode(value))
    }
}

/// Storage shared by an encoder and the containers it hands out, so nested
/// containers write back into their parent.
private final class Storage {
    enum Node {
        case empty
        case value(MsgpackValue)
        case array([Storage])
        case map([(key: MsgpackValue, value: Storage)])
    }

    var node: Node = .empty

    var resolved: MsgpackValue {
        switch node {
        case .empty: return .null
        case .value(let value): return value
        case .array(let items): return .array(items.map(\.resolved))
        case .map(let entries):
            var map: [MsgpackValue: MsgpackValue] = [:]
            for entry in entries { map[entry.key] = entry.value.resolved }
            return .map(map)
        }
    }

    /// Marks the node's shape up front. Without this an empty container stays
    /// `.empty` and resolves to null, so `[]` and `[:]` would encode as nil.
    func beginArray() {
        if case .empty = node { node = .array([]) }
    }

    func beginMap() {
        if case .empty = node { node = .map([]) }
    }

    func appendArrayElement() -> Storage {
        var items: [Storage]
        if case .array(let existing) = node { items = existing } else { items = [] }
        let child = Storage()
        items.append(child)
        node = .array(items)
        return child
    }

    func setMapEntry(_ key: MsgpackValue) -> Storage {
        var entries: [(key: MsgpackValue, value: Storage)]
        if case .map(let existing) = node { entries = existing } else { entries = [] }
        let child = Storage()
        entries.append((key, child))
        node = .map(entries)
        return child
    }
}

private struct _MsgpackEncoder: Encoder {
    let storage: Storage
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(codingPath: [any CodingKey], storage: Storage = Storage()) {
        self.storage = storage
        self.codingPath = codingPath
    }

    var resolved: MsgpackValue { storage.resolved }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        storage.beginMap()
        return KeyedEncodingContainer(_KeyedContainer(storage: storage, codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        storage.beginArray()
        return _UnkeyedContainer(storage: storage, codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        _SingleValueContainer(storage: storage, codingPath: codingPath)
    }
}

private struct _KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let storage: Storage
    let codingPath: [any CodingKey]

    private func child(_ key: Key) -> Storage {
        storage.setMapEntry(.string(key.stringValue))
    }

    mutating func encodeNil(forKey key: Key) throws {
        child(key).node = .value(.null)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let target = child(key)
        if let value = value as? MsgpackValue {
            target.node = .value(value)
            return
        }
        try value.encode(to: _MsgpackEncoder(codingPath: codingPath + [key], storage: target))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let target = child(key)
        target.beginMap()
        return KeyedEncodingContainer(_KeyedContainer<NestedKey>(storage: target,
                                                                 codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let target = child(key)
        target.beginArray()
        return _UnkeyedContainer(storage: target, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> any Encoder {
        _MsgpackEncoder(codingPath: codingPath, storage: storage)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        _MsgpackEncoder(codingPath: codingPath + [key], storage: child(key))
    }
}

private struct _UnkeyedContainer: UnkeyedEncodingContainer {
    let storage: Storage
    let codingPath: [any CodingKey]
    var count: Int {
        if case .array(let items) = storage.node { return items.count }
        return 0
    }

    mutating func encodeNil() throws {
        storage.appendArrayElement().node = .value(.null)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let target = storage.appendArrayElement()
        if let value = value as? MsgpackValue {
            target.node = .value(value)
            return
        }
        try value.encode(to: _MsgpackEncoder(codingPath: codingPath, storage: target))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let target = storage.appendArrayElement()
        target.beginMap()
        return KeyedEncodingContainer(_KeyedContainer<NestedKey>(storage: target,
                                                                 codingPath: codingPath))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let target = storage.appendArrayElement()
        target.beginArray()
        return _UnkeyedContainer(storage: target, codingPath: codingPath)
    }

    mutating func superEncoder() -> any Encoder {
        _MsgpackEncoder(codingPath: codingPath, storage: storage.appendArrayElement())
    }
}

private struct _SingleValueContainer: SingleValueEncodingContainer {
    let storage: Storage
    let codingPath: [any CodingKey]

    mutating func encodeNil() throws { storage.node = .value(.null) }
    mutating func encode(_ value: Bool) throws { storage.node = .value(.bool(value)) }
    mutating func encode(_ value: String) throws { storage.node = .value(.string(value)) }
    mutating func encode(_ value: Double) throws { storage.node = .value(.double(value)) }
    mutating func encode(_ value: Float) throws { storage.node = .value(.double(Double(value))) }

    // Signed values that are not negative encode as .uint so they take the same
    // wire form the server would send back, keeping round-trips stable.
    mutating func encode(_ value: Int) throws { encodeInteger(Int64(value)) }
    mutating func encode(_ value: Int8) throws { encodeInteger(Int64(value)) }
    mutating func encode(_ value: Int16) throws { encodeInteger(Int64(value)) }
    mutating func encode(_ value: Int32) throws { encodeInteger(Int64(value)) }
    mutating func encode(_ value: Int64) throws { encodeInteger(value) }
    mutating func encode(_ value: UInt) throws { storage.node = .value(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt8) throws { storage.node = .value(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt16) throws { storage.node = .value(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt32) throws { storage.node = .value(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt64) throws { storage.node = .value(.uint(value)) }

    private mutating func encodeInteger(_ value: Int64) {
        storage.node = .value(value < 0 ? .int(value) : .uint(UInt64(value)))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        if let value = value as? MsgpackValue {
            storage.node = .value(value)
            return
        }
        try value.encode(to: _MsgpackEncoder(codingPath: codingPath, storage: storage))
    }
}

/// Lets ``MsgpackValue`` appear directly in an Encodable model.
extension MsgpackValue: Encodable {
    public func encode(to encoder: any Encoder) throws {
        // MsgpackEncoder intercepts this type before it reaches here; this path is
        // for foreign encoders, where the value is projected onto their model.
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .uint(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .rawString(let bytes), .binary(let bytes): try container.encode(bytes)
        case .array(let items): try container.encode(items)
        case .bigInt(let sign, let magnitude):
            try container.encode((sign == .minus ? "-0x" : "0x") + hexEncode(magnitude))
        case .map(let entries):
            // Foreign encoders cannot express arbitrary keys; string keys survive.
            var out: [String: MsgpackValue] = [:]
            for (key, value) in entries {
                guard let key = key.stringValue else {
                    throw MsgpackError.unsupported("map key \(key) is not a string")
                }
                out[key] = value
            }
            try container.encode(out)
        case .ext(let code, let data):
            throw MsgpackError.unsupported("ext type \(code) with \(data.count) bytes")
        }
    }
}
