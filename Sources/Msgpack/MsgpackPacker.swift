/// Encodes ``MsgpackValue`` to bytes, matching `synapse.lib.msgpack`'s packer
/// configuration exactly: `use_bin_type=True`, float64 for every double, minimal
/// width for in-range integers, and ext 0/1 for everything wider than 64 bits.
///
/// Byte-exactness is a hard requirement, not an aesthetic one. Telepath does no
/// canonicalisation, so a divergence here does not surface until a live server
/// rejects a message.
public struct MsgpackPacker: Sendable {
    public init() {}

    public static func encode(_ value: MsgpackValue) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        MsgpackPacker().write(value, into: &out)
        return out
    }

    public func write(_ value: MsgpackValue, into out: inout [UInt8]) {
        switch value {
        case .null:
            out.append(0xc0)
        case .bool(let b):
            out.append(b ? 0xc3 : 0xc2)
        case .int(let i):
            writeInt(i, into: &out)
        case .uint(let u):
            writeUInt(u, into: &out)
        case .bigInt(let sign, let magnitude):
            writeBigInt(sign: sign, magnitude: magnitude, into: &out)
        case .double(let d):
            out.append(0xcb)
            appendBigEndian(d.bitPattern, into: &out)
        case .string(let s):
            writeStringBytes(Array(s.utf8), into: &out)
        case .rawString(let bytes):
            writeStringBytes(bytes, into: &out)
        case .binary(let bytes):
            writeBinary(bytes, into: &out)
        case .array(let items):
            writeArrayHeader(items.count, into: &out)
            for item in items { write(item, into: &out) }
        case .map(let entries):
            writeMapHeader(entries.count, into: &out)
            for (k, v) in entries {
                write(k, into: &out)
                write(v, into: &out)
            }
        case .ext(let code, let data):
            writeExt(code: code, data: data, into: &out)
        }
    }

    // MARK: integers

    private func writeInt(_ i: Int64, into out: inout [UInt8]) {
        if i >= 0 { return writeUInt(UInt64(i), into: &out) }
        if i >= -32 {
            out.append(UInt8(bitPattern: Int8(i)))
        } else if i >= -128 {
            out.append(0xd0)
            out.append(UInt8(bitPattern: Int8(i)))
        } else if i >= -32_768 {
            out.append(0xd1)
            appendBigEndian(UInt16(bitPattern: Int16(i)), into: &out)
        } else if i >= -2_147_483_648 {
            out.append(0xd2)
            appendBigEndian(UInt32(bitPattern: Int32(i)), into: &out)
        } else {
            out.append(0xd3)
            appendBigEndian(UInt64(bitPattern: i), into: &out)
        }
    }

    private func writeUInt(_ u: UInt64, into out: inout [UInt8]) {
        if u <= 0x7f {
            out.append(UInt8(u))
        } else if u <= 0xff {
            out.append(0xcc)
            out.append(UInt8(u))
        } else if u <= 0xffff {
            out.append(0xcd)
            appendBigEndian(UInt16(u), into: &out)
        } else if u <= 0xffff_ffff {
            out.append(0xce)
            appendBigEndian(UInt32(u), into: &out)
        } else {
            out.append(0xcf)
            appendBigEndian(u, into: &out)
        }
    }

    /// Reproduces Synapse's `_ext_en`. Width comes from Python's
    /// `int.to_bytes((bit_length + 7) // 8)` for ext 0 and
    /// `(bit_length + 8) // 8` signed for ext 1 — the latter is deliberately not
    /// minimal (`-2**127` occupies 17 bytes where 16 would do) and the padding is
    /// part of the wire format we must reproduce.
    private func writeBigInt(sign: MsgpackValue.Sign, magnitude: [UInt8], into out: inout [UInt8]) {
        let mag = BigIntBytes.stripLeadingZeros(magnitude)
        if sign == .plus {
            let payload = mag.isEmpty ? [0] : mag
            writeExt(code: 0, data: payload, into: &out)
        } else {
            let width = (BigIntBytes.bitLength(mag) + 8) / 8
            writeExt(code: 1, data: BigIntBytes.twosComplement(magnitude: mag, width: max(width, 1)), into: &out)
        }
    }

    // MARK: byte-carrying types

    private func writeStringBytes(_ bytes: [UInt8], into out: inout [UInt8]) {
        let n = bytes.count
        if n < 32 {
            out.append(0xa0 | UInt8(n))
        } else if n <= 0xff {
            out.append(0xd9); out.append(UInt8(n))
        } else if n <= 0xffff {
            out.append(0xda); appendBigEndian(UInt16(n), into: &out)
        } else {
            out.append(0xdb); appendBigEndian(UInt32(n), into: &out)
        }
        out.append(contentsOf: bytes)
    }

    private func writeBinary(_ bytes: [UInt8], into out: inout [UInt8]) {
        let n = bytes.count
        if n <= 0xff {
            out.append(0xc4); out.append(UInt8(n))
        } else if n <= 0xffff {
            out.append(0xc5); appendBigEndian(UInt16(n), into: &out)
        } else {
            out.append(0xc6); appendBigEndian(UInt32(n), into: &out)
        }
        out.append(contentsOf: bytes)
    }

    private func writeArrayHeader(_ n: Int, into out: inout [UInt8]) {
        if n < 16 {
            out.append(0x90 | UInt8(n))
        } else if n <= 0xffff {
            out.append(0xdc); appendBigEndian(UInt16(n), into: &out)
        } else {
            out.append(0xdd); appendBigEndian(UInt32(n), into: &out)
        }
    }

    private func writeMapHeader(_ n: Int, into out: inout [UInt8]) {
        if n < 16 {
            out.append(0x80 | UInt8(n))
        } else if n <= 0xffff {
            out.append(0xde); appendBigEndian(UInt16(n), into: &out)
        } else {
            out.append(0xdf); appendBigEndian(UInt32(n), into: &out)
        }
    }

    private func writeExt(code: Int8, data: [UInt8], into out: inout [UInt8]) {
        let n = data.count
        switch n {
        case 1: out.append(0xd4)
        case 2: out.append(0xd5)
        case 4: out.append(0xd6)
        case 8: out.append(0xd7)
        case 16: out.append(0xd8)
        default:
            if n <= 0xff {
                out.append(0xc7); out.append(UInt8(n))
            } else if n <= 0xffff {
                out.append(0xc8); appendBigEndian(UInt16(n), into: &out)
            } else {
                out.append(0xc9); appendBigEndian(UInt32(n), into: &out)
            }
        }
        out.append(UInt8(bitPattern: code))
        out.append(contentsOf: data)
    }

    private func appendBigEndian<T: FixedWidthInteger>(_ v: T, into out: inout [UInt8]) {
        withUnsafeBytes(of: v.bigEndian) { out.append(contentsOf: $0) }
    }
}

/// Big-endian magnitude arithmetic, kept minimal because the only operations the
/// protocol needs are two's complement conversion and bit counting.
enum BigIntBytes {
    static func stripLeadingZeros(_ bytes: [UInt8]) -> [UInt8] {
        guard let first = bytes.firstIndex(where: { $0 != 0 }) else { return [] }
        return Array(bytes[first...])
    }

    static func bitLength(_ magnitude: [UInt8]) -> Int {
        let mag = stripLeadingZeros(magnitude)
        guard let top = mag.first else { return 0 }
        return (mag.count - 1) * 8 + (8 - top.leadingZeroBitCount)
    }

    /// `-magnitude` as a two's complement big-endian value of exactly `width` bytes.
    static func twosComplement(magnitude: [UInt8], width: Int) -> [UInt8] {
        var padded = [UInt8](repeating: 0, count: max(0, width - magnitude.count))
        padded.append(contentsOf: magnitude.suffix(width))
        var out = padded.map { ~$0 }
        var carry: UInt16 = 1
        for i in stride(from: out.count - 1, through: 0, by: -1) {
            let sum = UInt16(out[i]) + carry
            out[i] = UInt8(sum & 0xff)
            carry = sum >> 8
            if carry == 0 { break }
        }
        return out
    }

    /// Inverse of ``twosComplement(magnitude:width:)``: recovers the positive
    /// magnitude of a negative two's complement big-endian payload.
    static func negate(twosComplement bytes: [UInt8]) -> [UInt8] {
        var out = bytes.map { ~$0 }
        var carry: UInt16 = 1
        for i in stride(from: out.count - 1, through: 0, by: -1) {
            let sum = UInt16(out[i]) + carry
            out[i] = UInt8(sum & 0xff)
            carry = sum >> 8
            if carry == 0 { break }
        }
        return stripLeadingZeros(out)
    }
}
