import Msgpack
import Telepath

/// Options for a Storm query. Mirrors the `opts` dict Synapse expects, carrying
/// only the fields most callers set; ``extra`` is the escape hatch for the rest.
public struct StormOpts: Sendable {
    public var vars: [String: MsgpackValue] = [:]
    /// Target view iden. Nil uses the user's default view.
    public var view: String?
    /// Ask the server to include human-readable property representations.
    public var repr: Bool = false
    public var limit: Int?
    public var extra: [String: MsgpackValue] = [:]

    public init(vars: [String: MsgpackValue] = [:], view: String? = nil,
                repr: Bool = false, limit: Int? = nil) {
        self.vars = vars
        self.view = view
        self.repr = repr
        self.limit = limit
    }

    var msgpack: MsgpackValue {
        var map: [MsgpackValue: MsgpackValue] = [:]
        for (key, value) in extra { map[.string(key)] = value }
        if !vars.isEmpty {
            var varsMap: [MsgpackValue: MsgpackValue] = [:]
            for (key, value) in vars { varsMap[.string(key)] = value }
            map[.string("vars")] = .map(varsMap)
        }
        if let view { map[.string("view")] = .string(view) }
        if repr { map[.string("repr")] = .bool(true) }
        if let limit { map[.string("limit")] = .int(Int64(limit)) }
        return .map(map)
    }
}

/// A typed facade over a Cortex proxy.
///
/// The proxy's generic `call`/`stream` remain available for anything not covered
/// here; this exists because the Storm path is where callers spend their time.
public struct Cortex: Sendable {
    public let proxy: Proxy

    public init(_ proxy: Proxy) {
        self.proxy = proxy
    }

    public static func open(_ url: String, config: Config = Config()) async throws -> Cortex {
        Cortex(try await Proxy.open(url, config: config))
    }

    public func close() async {
        await proxy.close()
    }

    /// The raw Storm message stream: init, nodes, prints, warnings, and fini.
    public func storm(_ text: String, opts: StormOpts = StormOpts()) -> StormStream {
        StormStream(
            base: proxy.stream("storm", [.string(text)], kwargs: ["opts": opts.msgpack]),
            throwOnErrorMessage: true
        )
    }

    /// Just the nodes — the 80% call path. An `err` message in the stream is
    /// rethrown as a Swift error rather than silently ending the sequence.
    public func nodes(_ text: String, opts: StormOpts = StormOpts()) -> NodeStream {
        NodeStream(base: storm(text, opts: opts))
    }

    /// Runs a query that ends in `return(...)` and decodes the returned value.
    public func callStorm<T: Decodable>(
        _ text: String,
        opts: StormOpts = StormOpts(),
        returning type: T.Type
    ) async throws -> T {
        let value = try await proxy.call("callStorm", [.string(text)], kwargs: ["opts": opts.msgpack])
        return try MsgpackDecoder().decode(type, from: value)
    }

    public func callStorm(_ text: String, opts: StormOpts = StormOpts()) async throws -> MsgpackValue {
        try await proxy.call("callStorm", [.string(text)], kwargs: ["opts": opts.msgpack])
    }

    /// Counts a query's nodes without transferring them.
    public func count(_ text: String, opts: StormOpts = StormOpts()) async throws -> Int {
        let value = try await proxy.call("count", [.string(text)], kwargs: ["opts": opts.msgpack])
        return value.intValue.map(Int.init) ?? 0
    }

    public func getCellInfo() async throws -> CellInfo {
        try await MsgpackDecoder().decode(CellInfo.self, from: proxy.call("getCellInfo"))
    }

    /// Validates a query server-side without running it.
    public func reqValidStorm(_ text: String) async throws {
        _ = try await proxy.call("reqValidStorm", [.string(text)])
    }
}

/// A Storm query in progress. Preserves the underlying link ownership rules:
/// abandoning it early closes the link rather than draining the query.
public struct StormStream: AsyncSequence, Sendable {
    public typealias Element = StormMessage

    let base: TelepathStream
    let throwOnErrorMessage: Bool

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator(), throwOnErrorMessage: throwOnErrorMessage)
    }

    public struct Iterator: AsyncIteratorProtocol {
        var base: TelepathStream.Iterator
        let throwOnErrorMessage: Bool

        public mutating func next() async throws -> StormMessage? {
            guard let raw = try await base.next() else { return nil }
            let message = try StormMessage(raw)
            if throwOnErrorMessage, case .err(let error) = message {
                throw StormError.queryFailed(error)
            }
            return message
        }
    }
}

public struct NodeStream: AsyncSequence, Sendable {
    public typealias Element = Node

    let base: StormStream

    /// Collects every node. Bounded queries only — prefer iterating a large one.
    public func collect() async throws -> [Node] {
        var nodes: [Node] = []
        for try await node in self { nodes.append(node) }
        return nodes
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        var base: StormStream.Iterator

        public mutating func next() async throws -> Node? {
            while let message = try await base.next() {
                if case .node(let node) = message { return node }
            }
            return nil
        }
    }
}

public struct CellInfo: Sendable, Decodable {
    public struct Cell: Sendable, Decodable {
        public let type: String?
        public let iden: String?
        public let active: Bool?
        public let ready: Bool?
    }

    public struct SynapseVersion: Sendable, Decodable {
        public let version: [Int]?
        public let commit: String?

        private enum CodingKeys: String, CodingKey {
            case version, commit
        }

        /// 2.x reports `synapse.version` as a tuple of integers, 3.0 as the dotted
        /// string `"3.0.0"`. Decoding only the tuple threw a type mismatch against
        /// 3.0, taking the whole of `getCellInfo` down with it.
        ///
        /// Every branch is lenient for the same reason: this is metadata about the
        /// server, and a shape nobody anticipated should leave one field nil, not
        /// fail the call that carries it. A third shape in some future release
        /// would otherwise reproduce exactly the bug this decoder exists to fix.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.commit = try? container.decodeIfPresent(String.self, forKey: .commit)
            if let parts = try? container.decodeIfPresent([Int].self, forKey: .version) {
                self.version = parts
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .version) {
                self.version = SynapseVersionParsing.parse(text)
            } else {
                self.version = nil
            }
        }
    }

    public let cell: Cell?
    public let synapse: SynapseVersion?

    public var versionString: String? {
        synapse?.version.map { $0.map(String.init).joined(separator: ".") }
    }
}
