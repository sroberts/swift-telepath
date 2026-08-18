public enum MsgpackError: Error, Hashable, Sendable {
    /// The buffer ended mid-value. Streaming callers wait for more bytes; one-shot
    /// callers treat it as truncation.
    case insufficientData
    case invalidFormatByte(UInt8)
    /// A length prefix exceeded `maxBufferSize` or the remaining buffer.
    case lengthOutOfRange(UInt64)
    case nestingTooDeep(limit: Int)
    /// Trailing bytes after a complete value where exactly one was expected.
    case trailingData(byteCount: Int)
    /// A `.rawString` reached a `String` in a Codable model.
    case invalidUTF8(path: String)
    /// A big integer did not fit the requested fixed-width type.
    case integerOverflow(String)
    case typeMismatch(expected: String, actual: String, path: String)
    case keyNotFound(String, path: String)
    case valueNotFound(String, path: String)
    case unsupported(String)
}
