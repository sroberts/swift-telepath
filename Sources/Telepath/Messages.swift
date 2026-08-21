import Msgpack

/// Method shape metadata from the handshake's `sharinfo['meths']`.
///
/// `genr` is the only method-shape information the protocol provides, and it is
/// what decides whether a caller gets a value or an `AsyncSequence`.
public struct MethodInfo: Sendable, Equatable {
    public let name: String
    public let isGenerator: Bool
}

/// The server's description of the shared object, returned by the handshake.
public struct ShareInfo: Sendable {
    public let methods: [String: MethodInfo]
    public let synapseVersion: [Int]?
    public let synapseCommit: String?
    public let classes: [String]
    public let raw: MsgpackValue

    init(_ value: MsgpackValue) {
        self.raw = value
        var methods: [String: MethodInfo] = [:]
        if case .map(let meths)? = value["meths"] {
            for (key, info) in meths {
                guard let name = key.stringValue else { continue }
                let isGenerator = info["genr"]?.boolValue ?? false
                methods[name] = MethodInfo(name: name, isGenerator: isGenerator)
            }
        }
        self.methods = methods
        self.synapseVersion = SynapseVersionParsing.parse(value["syn:version"])
        self.synapseCommit = value["syn:commit"]?.stringValue
        self.classes = value["classes"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

/// Synapse reports its own version two different ways, so both are accepted.
///
/// 2.x packs `syn:version` as a tuple of integers; 3.0 packs it as the dotted
/// string `"3.0.0"`, and the same change reaches `getCellInfo`. Reading only the
/// tuple made ``Proxy/serverVersion`` return nil against a 3.0 server, which is a
/// silent wrong answer rather than a failure — worse than either shape.
enum SynapseVersionParsing {
    static func parse(_ value: MsgpackValue?) -> [Int]? {
        guard let value else { return nil }
        if let items = value.arrayValue {
            let parts = items.compactMap { $0.intValue.map(Int.init) }
            return parts.count == items.count ? parts : nil
        }
        if let text = value.stringValue {
            return parse(text)
        }
        return nil
    }

    /// A dotted numeric string, all-or-nothing. A partial parse of something like
    /// `"3.0.0-rc1"` would compare wrong, so it is rejected instead.
    static func parse(_ text: String) -> [Int]? {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        let parts = fields.compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == fields.count else { return nil }
        return parts
    }
}

/// Decoding for Synapse's universal result convention: every result is a tuple of
/// `(True, value)` or `(False, (excName, info))`.
enum Retn {
    /// Unwraps a retn tuple, throwing ``TelepathRemoteError`` on the failure arm.
    static func unwrap(_ value: MsgpackValue) throws -> MsgpackValue {
        guard let items = value.arrayValue, items.count == 2 else {
            throw TelepathError.protocolViolation("expected a 2-element retn tuple, got \(value)")
        }
        guard let ok = items[0].boolValue else {
            throw TelepathError.protocolViolation("retn tuple had a non-boolean status: \(items[0])")
        }
        if ok { return items[1] }
        throw remoteError(items[1])
    }

    static func remoteError(_ value: MsgpackValue) -> TelepathRemoteError {
        TelepathRemoteError(errorTuple: value)
    }
}

/// A decoded Telepath message: every message on the wire is `(name, infoMap)`.
struct Message {
    let name: String
    let info: MsgpackValue

    init(_ value: MsgpackValue) throws {
        guard let items = value.arrayValue, items.count == 2, let name = items[0].stringValue else {
            throw TelepathError.protocolViolation("expected a (name, info) message, got \(value)")
        }
        self.name = name
        self.info = items[1]
    }

    subscript(key: String) -> MsgpackValue? { info[key] }
}
