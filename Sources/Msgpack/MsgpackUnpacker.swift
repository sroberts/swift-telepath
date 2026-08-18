/// Decodes bytes to ``MsgpackValue``, matching `synapse.lib.msgpack`'s unpacker:
/// `raw=False` (str decodes as text, bin as bytes), `strict_map_key=False`
/// (arbitrary map keys), and an ext hook that understands only codes 0 and 1.
///
/// A msgpack `str` whose bytes are not valid UTF-8 becomes ``MsgpackValue/rawString(_:)``
/// rather than an error — Synapse packs with `surrogatepass`, so lone surrogates
/// occur in real data.
public struct MsgpackUnpacker: Sendable {
    /// Matches Python's `max_buffer_size` of `2**32 - 1`.
    public static let maxBufferSize: UInt64 = 0xffff_ffff
    public static let defaultDepthLimit = 512

    public let depthLimit: Int

    public init(depthLimit: Int = MsgpackUnpacker.defaultDepthLimit) {
        self.depthLimit = depthLimit
    }

    /// Decodes exactly one value, rejecting trailing bytes.
    public static func decode(_ bytes: [UInt8]) throws -> MsgpackValue {
        var cursor = 0
        let value = try MsgpackUnpacker().decodeValue(bytes, &cursor, depth: 0)
        guard cursor == bytes.count else {
            throw MsgpackError.trailingData(byteCount: bytes.count - cursor)
        }
        return value
    }

    /// Decodes one value from `bytes` starting at `cursor`, advancing it.
    /// Throws ``MsgpackError/insufficientData`` when the buffer ends mid-value,
    /// which streaming callers treat as "wait for more bytes".
    public func decodeValue(_ bytes: [UInt8], _ cursor: inout Int, depth: Int) throws -> MsgpackValue {
        guard depth <= depthLimit else { throw MsgpackError.nestingTooDeep(limit: depthLimit) }
        let byte = try readByte(bytes, &cursor)

        switch byte {
        case 0x00...0x7f: return .uint(UInt64(byte))
        case 0xe0...0xff: return .int(Int64(Int8(bitPattern: byte)))
        case 0x80...0x8f: return try readMap(bytes, &cursor, count: Int(byte & 0x0f), depth: depth)
        case 0x90...0x9f: return try readArray(bytes, &cursor, count: Int(byte & 0x0f), depth: depth)
        case 0xa0...0xbf: return try readString(bytes, &cursor, count: Int(byte & 0x1f))
        case 0xc0: return .null
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xc4: return .binary(try readBytes(bytes, &cursor, count: Int(try readByte(bytes, &cursor))))
        case 0xc5: return .binary(try readBytes(bytes, &cursor, count: try readLength(bytes, &cursor, UInt16.self)))
        case 0xc6: return .binary(try readBytes(bytes, &cursor, count: try readLength(bytes, &cursor, UInt32.self)))
        case 0xc7: return try readExt(bytes, &cursor, count: Int(try readByte(bytes, &cursor)))
        case 0xc8: return try readExt(bytes, &cursor, count: try readLength(bytes, &cursor, UInt16.self))
        case 0xc9: return try readExt(bytes, &cursor, count: try readLength(bytes, &cursor, UInt32.self))
        case 0xca:
            return .double(Double(Float(bitPattern: try readFixed(bytes, &cursor, UInt32.self))))
        case 0xcb:
            return .double(Double(bitPattern: try readFixed(bytes, &cursor, UInt64.self)))
        case 0xcc: return .uint(UInt64(try readByte(bytes, &cursor)))
        case 0xcd: return .uint(UInt64(try readFixed(bytes, &cursor, UInt16.self)))
        case 0xce: return .uint(UInt64(try readFixed(bytes, &cursor, UInt32.self)))
        case 0xcf: return .uint(try readFixed(bytes, &cursor, UInt64.self))
        case 0xd0: return .int(Int64(Int8(bitPattern: try readByte(bytes, &cursor))))
        case 0xd1: return .int(Int64(Int16(bitPattern: try readFixed(bytes, &cursor, UInt16.self))))
        case 0xd2: return .int(Int64(Int32(bitPattern: try readFixed(bytes, &cursor, UInt32.self))))
        case 0xd3: return .int(Int64(bitPattern: try readFixed(bytes, &cursor, UInt64.self)))
        case 0xd4: return try readExt(bytes, &cursor, count: 1)
        case 0xd5: return try readExt(bytes, &cursor, count: 2)
        case 0xd6: return try readExt(bytes, &cursor, count: 4)
        case 0xd7: return try readExt(bytes, &cursor, count: 8)
        case 0xd8: return try readExt(bytes, &cursor, count: 16)
        case 0xd9: return try readString(bytes, &cursor, count: Int(try readByte(bytes, &cursor)))
        case 0xda: return try readString(bytes, &cursor, count: try readLength(bytes, &cursor, UInt16.self))
        case 0xdb: return try readString(bytes, &cursor, count: try readLength(bytes, &cursor, UInt32.self))
        case 0xdc: return try readArray(bytes, &cursor, count: try readLength(bytes, &cursor, UInt16.self), depth: depth)
        case 0xdd: return try readArray(bytes, &cursor, count: try readLength(bytes, &cursor, UInt32.self), depth: depth)
        case 0xde: return try readMap(bytes, &cursor, count: try readLength(bytes, &cursor, UInt16.self), depth: depth)
        case 0xdf: return try readMap(bytes, &cursor, count: try readLength(bytes, &cursor, UInt32.self), depth: depth)
        default: throw MsgpackError.invalidFormatByte(byte)
        }
    }

    // MARK: primitives

    private func readByte(_ bytes: [UInt8], _ cursor: inout Int) throws -> UInt8 {
        guard cursor < bytes.count else { throw MsgpackError.insufficientData }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    private func readFixed<T: FixedWidthInteger>(_ bytes: [UInt8], _ cursor: inout Int, _ type: T.Type) throws -> T {
        let width = MemoryLayout<T>.size
        guard cursor + width <= bytes.count else { throw MsgpackError.insufficientData }
        defer { cursor += width }
        var value: T = 0
        for i in 0..<width { value = (value << 8) | T(bytes[cursor + i]) }
        return value
    }

    private func readLength<T: FixedWidthInteger>(_ bytes: [UInt8], _ cursor: inout Int, _ type: T.Type) throws -> Int {
        let raw = UInt64(try readFixed(bytes, &cursor, type))
        guard raw <= Self.maxBufferSize else { throw MsgpackError.lengthOutOfRange(raw) }
        return Int(raw)
    }

    private func readBytes(_ bytes: [UInt8], _ cursor: inout Int, count: Int) throws -> [UInt8] {
        guard count >= 0, cursor + count <= bytes.count else { throw MsgpackError.insufficientData }
        defer { cursor += count }
        return Array(bytes[cursor..<(cursor + count)])
    }

    // MARK: composite

    private func readString(_ bytes: [UInt8], _ cursor: inout Int, count: Int) throws -> MsgpackValue {
        let raw = try readBytes(bytes, &cursor, count: count)
        // surrogatepass output is not representable as a Swift String; keep the bytes.
        // Strict validation, not lossy decoding: UTF-8 encoded surrogates must
        // fail here so they are preserved as bytes rather than mangled to U+FFFD.
        if isStrictUTF8(raw) {
            return .string(String(decoding: raw, as: UTF8.self))
        }
        return .rawString(raw)
    }

    private func readArray(_ bytes: [UInt8], _ cursor: inout Int, count: Int, depth: Int) throws -> MsgpackValue {
        var items: [MsgpackValue] = []
        items.reserveCapacity(Swift.min(count, 1024))
        for _ in 0..<count {
            items.append(try decodeValue(bytes, &cursor, depth: depth + 1))
        }
        return .array(items)
    }

    private func readMap(_ bytes: [UInt8], _ cursor: inout Int, count: Int, depth: Int) throws -> MsgpackValue {
        var entries: [MsgpackValue: MsgpackValue] = [:]
        entries.reserveCapacity(Swift.min(count, 1024))
        for _ in 0..<count {
            let key = try decodeValue(bytes, &cursor, depth: depth + 1)
            let value = try decodeValue(bytes, &cursor, depth: depth + 1)
            entries[key] = value
        }
        return .map(entries)
    }

    /// Ext 0 and ext 1 are the only codes Telepath defines, both meaning "integer
    /// too wide for 64 bits". Any other code is preserved as ``MsgpackValue/ext(code:data:)``
    /// so the Telepath layer can raise a precise protocol error rather than crashing.
    private func readExt(_ bytes: [UInt8], _ cursor: inout Int, count: Int) throws -> MsgpackValue {
        let code = Int8(bitPattern: try readByte(bytes, &cursor))
        let data = try readBytes(bytes, &cursor, count: count)
        switch code {
        case 0:
            return .bigInt(sign: .plus, magnitude: BigIntBytes.stripLeadingZeros(data))
        case 1:
            // Two's complement big-endian. The sign lives in the top bit.
            guard let first = data.first else { throw MsgpackError.insufficientData }
            if first & 0x80 != 0 {
                return .bigInt(sign: .minus, magnitude: BigIntBytes.negate(twosComplement: data))
            }
            return .bigInt(sign: .plus, magnitude: BigIntBytes.stripLeadingZeros(data))
        default:
            return .ext(code: code, data: data)
        }
    }
}

// MARK: - Streaming

/// Incremental unpacker for the Telepath link, which carries an unframed msgpack
/// stream: bytes arrive in arbitrary chunks and each complete value is dispatched
/// as soon as it lands. There is no length prefix to seek to.
public struct MsgpackStreamUnpacker: Sendable {
    private var buffer: [UInt8] = []
    private var offset = 0
    private let unpacker: MsgpackUnpacker

    public init(depthLimit: Int = MsgpackUnpacker.defaultDepthLimit) {
        self.unpacker = MsgpackUnpacker(depthLimit: depthLimit)
    }

    public var pendingByteCount: Int { buffer.count - offset }

    public mutating func append<S: Sequence<UInt8>>(_ bytes: S) {
        buffer.append(contentsOf: bytes)
    }

    /// Returns the next complete value, or nil when more bytes are needed.
    /// Partial input is retained; malformed input throws and leaves the stream
    /// unusable, which is correct — a framing error on an unframed stream is
    /// unrecoverable and the link must be closed.
    public mutating func next() throws -> MsgpackValue? {
        guard offset < buffer.count else {
            compact()
            return nil
        }
        var cursor = offset
        do {
            let value = try unpacker.decodeValue(buffer, &cursor, depth: 0)
            offset = cursor
            compact()
            return value
        } catch MsgpackError.insufficientData {
            return nil
        }
    }

    /// Drops consumed bytes once they dominate the buffer, so a long-lived link
    /// does not grow without bound.
    private mutating func compact() {
        guard offset > 0 else { return }
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset > 65_536 {
            buffer.removeFirst(offset)
            offset = 0
        }
    }
}


/// Strict UTF-8 validation, rejecting overlong forms, out-of-range scalars, and —
/// the case that matters here — the surrogate range `U+D800...U+DFFF`, which
/// Synapse emits via `unicode_errors='surrogatepass'` as `ED A0 80`...`ED BF BF`.
///
/// `String(decoding:as:)` would silently substitute U+FFFD and destroy those bytes,
/// so validity is decided before any conversion happens.
func isStrictUTF8(_ bytes: [UInt8]) -> Bool {
    var i = 0
    let n = bytes.count
    while i < n {
        let b = bytes[i]
        let (extra, lo, hi): (Int, UInt8, UInt8)
        switch b {
        case 0x00...0x7f: i += 1; continue
        case 0xc2...0xdf: (extra, lo, hi) = (1, 0x80, 0xbf)
        case 0xe0:        (extra, lo, hi) = (2, 0xa0, 0xbf)   // reject overlong
        case 0xe1...0xec: (extra, lo, hi) = (2, 0x80, 0xbf)
        case 0xed:        (extra, lo, hi) = (2, 0x80, 0x9f)   // reject surrogates
        case 0xee...0xef: (extra, lo, hi) = (2, 0x80, 0xbf)
        case 0xf0:        (extra, lo, hi) = (3, 0x90, 0xbf)   // reject overlong
        case 0xf1...0xf3: (extra, lo, hi) = (3, 0x80, 0xbf)
        case 0xf4:        (extra, lo, hi) = (3, 0x80, 0x8f)   // reject > U+10FFFF
        default: return false
        }
        guard i + extra < n else { return false }
        guard bytes[i + 1] >= lo, bytes[i + 1] <= hi else { return false }
        for j in 2...max(2, extra) where j <= extra {
            guard bytes[i + j] >= 0x80, bytes[i + j] <= 0xbf else { return false }
        }
        i += extra + 1
    }
    return true
}

/// Public wrapper over the strict validator, so test and fuzz tooling can build
/// byte sequences that are guaranteed to be invalid UTF-8.
public func isStrictUTF8Public(_ bytes: [UInt8]) -> Bool { isStrictUTF8(bytes) }
