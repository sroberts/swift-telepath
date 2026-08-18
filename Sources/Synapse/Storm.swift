import Msgpack
import Telepath

/// One message from a Storm query's stream.
///
/// `.other` is not optional politeness: Vertex adds message kinds between minor
/// releases, and a client that throws on an unknown kind breaks on upgrade.
public enum StormMessage: Sendable {
    case initialized(StormInit)
    case node(Node)
    case nodeEdits(MsgpackValue)
    case print(String)
    case warn(StormWarn)
    case err(TelepathRemoteError)
    case finished(StormFini)
    case fire(name: String, data: MsgpackValue)
    case other(name: String, data: MsgpackValue)

    /// Every Storm message is a `(kind, payload)` tuple.
    public init(_ value: MsgpackValue) throws {
        guard let items = value.arrayValue, items.count == 2, let kind = items[0].stringValue else {
            throw StormError.malformedMessage(value)
        }
        let payload = items[1]
        switch kind {
        case "init":    self = .initialized(StormInit(payload))
        case "node":    self = .node(try Node(payload))
        case "node:edits", "node:edits:count": self = .nodeEdits(payload)
        case "print":   self = .print(payload["mesg"]?.stringValue ?? "")
        case "warn":    self = .warn(StormWarn(payload))
        case "err":     self = .err(TelepathRemoteError(errorTuple: payload))
        case "fini":    self = .finished(StormFini(payload))
        case "storm:fire":
            self = .fire(name: payload["type"]?.stringValue ?? "", data: payload["data"] ?? .null)
        default:
            self = .other(name: kind, data: payload)
        }
    }
}

public struct StormInit: Sendable {
    public let task: String?
    public let text: String?
    public let tick: Int64?
    public let raw: MsgpackValue

    init(_ value: MsgpackValue) {
        self.task = value["task"]?.stringValue
        self.text = value["text"]?.stringValue
        self.tick = value["tick"]?.intValue
        self.raw = value
    }
}

public struct StormFini: Sendable {
    public let count: Int
    /// Wall-clock duration of the query in milliseconds, as measured by the server.
    public let took: Int64?
    public let raw: MsgpackValue

    init(_ value: MsgpackValue) {
        self.count = value["count"]?.intValue.map(Int.init) ?? 0
        self.took = value["took"]?.intValue
        self.raw = value
    }
}

public struct StormWarn: Sendable {
    public let mesg: String
    public let raw: MsgpackValue

    init(_ value: MsgpackValue) {
        self.mesg = value["mesg"]?.stringValue ?? ""
        self.raw = value
    }
}

/// A node as emitted into a Storm stream (a "pode").
///
/// The wire shape is a tuple `(ndef, info)` rather than a map, so this decodes
/// positionally instead of via Codable.
public struct Node: Sendable {
    public let form: String
    public let value: MsgpackValue
    public let iden: String?
    public let tags: [String: MsgpackValue]
    public let props: [String: MsgpackValue]
    public let tagprops: [String: MsgpackValue]
    public let nodedata: [String: MsgpackValue]
    /// Pivot metadata, populated only when the query used `--path`.
    public let path: [String: MsgpackValue]

    public init(_ value: MsgpackValue) throws {
        guard let items = value.arrayValue, items.count == 2,
              let ndef = items[0].arrayValue, ndef.count == 2,
              let form = ndef[0].stringValue else {
            throw StormError.malformedNode(value)
        }
        self.form = form
        self.value = ndef[1]

        let info = items[1]
        self.iden = info["iden"]?.stringValue
        self.tags = Node.stringKeyed(info["tags"])
        self.props = Node.stringKeyed(info["props"])
        self.tagprops = Node.stringKeyed(info["tagprops"])
        self.nodedata = Node.stringKeyed(info["nodedata"])
        self.path = Node.stringKeyed(info["path"])
    }

    /// The node's primary property as text, when it is textual.
    public var repr: String? { value.stringValue }

    public subscript(prop: String) -> MsgpackValue? { props[prop] }

    /// True when the node carries `tag`, ignoring its time interval.
    public func hasTag(_ tag: String) -> Bool { tags[tag] != nil }

    private static func stringKeyed(_ value: MsgpackValue?) -> [String: MsgpackValue] {
        guard case .map(let map)? = value else { return [:] }
        var out: [String: MsgpackValue] = [:]
        out.reserveCapacity(map.count)
        for (key, entry) in map {
            if let key = key.stringValue { out[key] = entry }
        }
        return out
    }
}

public enum StormError: Error, Sendable {
    case malformedMessage(MsgpackValue)
    case malformedNode(MsgpackValue)
    /// A query emitted an `err` message; the stream is over.
    case queryFailed(TelepathRemoteError)
}
