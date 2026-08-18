import Foundation
import Logging
import Msgpack
import NIOCore
import NIOPosix
import TelepathTLS

public struct Config: Sendable {
    public var connectTimeout: Duration = .seconds(10)
    /// Client-side deadline for a call. Nil means wait indefinitely, matching Synapse.
    public var callTimeout: Duration?
    public var poolLowWater: Int = 4
    public var poolHighWater: Int = 12
    public var poolCullInterval: Duration = .seconds(10)
    /// Where to find Synapse's certificate directory. A `certdir` in the URL wins
    /// over this; both fall back to Synapse's default location.
    public var certificateDirectory: URL?
    public var logger = Logger(label: "telepath")

    public init() {}
}

/// A connected Telepath client.
///
/// The proxy owns one *main* link, created by the handshake and kept open for
/// out-of-band traffic and share teardown, plus a pool of additional links. Every
/// call occupies a link exclusively from `t2:init` until its terminator, so the
/// pool size bounds call concurrency, not throughput.
public actor Proxy {
    public let url: TelepathURL
    public let config: Config

    private let group: any EventLoopGroup
    private let ownsGroup: Bool
    private let mainLink: Link
    private var idleLinks: [Link] = []
    private var closed = false
    private var cullTask: Task<Void, Never>?

    /// The session iden from the handshake. Pool links skip the handshake entirely,
    /// so this value is the only thing binding them to an authenticated session.
    public let sessionIden: String
    public let shareInfo: ShareInfo
    public let features: [String: Int]
    public let protocolVersion: [Int]

    public var methods: [String: MethodInfo] { shareInfo.methods }
    public var serverVersion: [Int]? { shareInfo.synapseVersion }

    private static let protocolVersionOurs = [3, 0]

    private init(
        url: TelepathURL,
        config: Config,
        group: any EventLoopGroup,
        ownsGroup: Bool,
        mainLink: Link,
        sessionIden: String,
        shareInfo: ShareInfo,
        features: [String: Int],
        protocolVersion: [Int]
    ) {
        self.url = url
        self.config = config
        self.group = group
        self.ownsGroup = ownsGroup
        self.mainLink = mainLink
        self.sessionIden = sessionIden
        self.shareInfo = shareInfo
        self.features = features
        self.protocolVersion = protocolVersion
    }

    // MARK: - Opening

    public static func open(_ string: String, config: Config = Config()) async throws -> Proxy {
        try await open(TelepathURL(string), config: config)
    }

    public static func open(
        _ url: TelepathURL,
        config: Config = Config(),
        group: (any EventLoopGroup)? = nil
    ) async throws -> Proxy {
        let eventLoopGroup = group ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let ownsGroup = group == nil
        do {
            let link = try await Link.connect(
                to: url,
                group: eventLoopGroup,
                timeout: TimeAmount(config.connectTimeout),
                certificateDirectory: config.certificateDirectory.map { CertificateDirectory(root: $0) })
            let result = try await Self.handshake(on: link, url: url)
            let proxy = Proxy(url: url, config: config, group: eventLoopGroup, ownsGroup: ownsGroup,
                              mainLink: link, sessionIden: result.session, shareInfo: result.shareInfo,
                              features: result.features, protocolVersion: result.version)
            await proxy.startCulling()
            return proxy
        } catch {
            if ownsGroup { try? await eventLoopGroup.shutdownGracefully() }
            throw error
        }
    }

    private struct HandshakeResult {
        let session: String
        let shareInfo: ShareInfo
        let features: [String: Int]
        let version: [Int]
    }

    private static func handshake(on link: Link, url: TelepathURL) async throws -> HandshakeResult {
        // When a user is supplied without a password, Synapse authenticates from a
        // TLS client certificate and 'auth' stays None.
        var auth: MsgpackValue = .null
        if let user = url.user, let password = url.password {
            auth = .array([.string(user), .map([.string("passwd"): .string(password)])])
        }

        try await link.send(.array([
            .string("tele:syn"),
            .map([
                .string("auth"): auth,
                .string("vers"): .array([.uint(3), .uint(0)]),
                .string("name"): .string(url.share),
            ]),
        ]))

        let message = try Message(try await link.receiveRequired())
        guard message.name == "tele:syn" else {
            throw TelepathError.handshakeFailed("expected tele:syn, got \(message.name)")
        }

        let version = message["vers"]?.arrayValue?.compactMap { $0.intValue.map(Int.init) } ?? []
        // Only the major version is compatibility-significant.
        guard version.first == protocolVersionOurs[0] else {
            throw TelepathError.versionMismatch(theirs: version, ours: protocolVersionOurs)
        }

        // The retn carries authentication and share-lookup failures.
        guard let retn = message["retn"] else {
            throw TelepathError.handshakeFailed("handshake reply had no retn")
        }
        _ = try Retn.unwrap(retn)

        // No session iden means a pre-2.166 peer offering only task v1. Detected
        // explicitly rather than silently degrading to an unsupported path.
        guard let session = message["sess"]?.stringValue else {
            throw TelepathError.taskV1NotSupported
        }

        var features: [String: Int] = [:]
        if case .map(let raw)? = message["features"] {
            for (key, value) in raw {
                guard let name = key.stringValue else { continue }
                features[name] = value.intValue.map(Int.init) ?? (value.boolValue == true ? 1 : 0)
            }
        }

        return HandshakeResult(
            session: session,
            shareInfo: ShareInfo(message["sharinfo"] ?? .null),
            features: features,
            version: version
        )
    }

    /// Feature gating: `features[name]` is a version integer, not a flag.
    public func hasFeature(_ name: String, minVersion: Int = 1) -> Bool {
        (features[name] ?? 0) >= minVersion
    }

    // MARK: - Calls

    /// Issues a unary call and returns its result.
    public func call(
        _ method: String,
        _ args: [MsgpackValue] = [],
        kwargs: [String: MsgpackValue] = [:],
        share: String? = nil
    ) async throws -> MsgpackValue {
        let link = try await takeLink()
        do {
            try await link.send(Self.taskInit(method, args, kwargs, share: share, session: sessionIden))
            let message = try Message(try await link.receiveRequired())

            switch message.name {
            case "t2:fini":
                guard let retn = message["retn"] else {
                    throw TelepathError.protocolViolation("t2:fini carried no retn")
                }
                let value = try Retn.unwrap(retn)
                // Only a cleanly terminated call may return its link to the pool.
                await release(link)
                return value

            case "t2:genr":
                // The caller asked for a value from a generator method. Draining an
                // unbounded stream to be helpful is worse than saying so.
                await link.close()
                throw TelepathError.protocolViolation(
                    "'\(method)' is a generator; call stream(_:) instead of call(_:)")

            case "t2:share":
                await link.close()
                throw TelepathError.protocolViolation(
                    "'\(method)' returned a dynamic share, which is not supported yet")

            default:
                await link.close()
                throw TelepathError.protocolViolation("unexpected reply to t2:init: \(message.name)")
            }
        } catch let error as TelepathRemoteError {
            // A remote exception is a normal, complete exchange: the link is clean.
            await release(link)
            throw error
        } catch {
            await link.close()
            throw error
        }
    }

    /// Issues a generator call. The `t2:init` is not sent until the first iteration,
    /// matching Synapse's GenrIter, so constructing a stream is free.
    public nonisolated func stream(
        _ method: String,
        _ args: [MsgpackValue] = [],
        kwargs: [String: MsgpackValue] = [:],
        share: String? = nil
    ) -> TelepathStream {
        TelepathStream(proxy: self, method: method, args: args, kwargs: kwargs, share: share)
    }

    static func taskInit(
        _ method: String,
        _ args: [MsgpackValue],
        _ kwargs: [String: MsgpackValue],
        share: String?,
        session: String
    ) -> MsgpackValue {
        var kwargsMap: [MsgpackValue: MsgpackValue] = [:]
        for (key, value) in kwargs { kwargsMap[.string(key)] = value }
        return .array([
            .string("t2:init"),
            .map([
                .string("todo"): .array([.string(method), .array(args), .map(kwargsMap)]),
                .string("name"): share.map { MsgpackValue.string($0) } ?? .null,
                .string("sess"): .string(session),
            ]),
        ])
    }

    /// Opens a generator call and hands the caller its exclusively-owned link.
    func beginStream(
        method: String,
        args: [MsgpackValue],
        kwargs: [String: MsgpackValue],
        share: String?
    ) async throws -> Link {
        let link = try await takeLink()
        do {
            try await link.send(Self.taskInit(method, args, kwargs, share: share, session: sessionIden))
            let message = try Message(try await link.receiveRequired())
            switch message.name {
            case "t2:genr":
                return link
            case "t2:fini":
                // A non-generator method reached stream(); surface its result shape.
                guard let retn = message["retn"] else {
                    throw TelepathError.protocolViolation("t2:fini carried no retn")
                }
                _ = try Retn.unwrap(retn)
                await release(link)
                throw TelepathError.protocolViolation(
                    "'\(method)' is not a generator; call call(_:) instead of stream(_:)")
            default:
                await link.close()
                throw TelepathError.protocolViolation("unexpected reply to t2:init: \(message.name)")
            }
        } catch let error as TelepathRemoteError {
            await release(link)
            throw error
        } catch {
            await link.close()
            throw error
        }
    }

    // MARK: - Pool

    /// Takes an idle link or opens a new one. Pool links skip the handshake and go
    /// straight to `t2:init` carrying the session iden.
    private func takeLink() async throws -> Link {
        guard !closed else { throw TelepathError.proxyClosed }
        while let link = idleLinks.popLast() {
            if link.isActive { return link }
        }
        return try await Link.connect(
            to: url,
            group: group,
            timeout: TimeAmount(config.connectTimeout),
            certificateDirectory: config.certificateDirectory.map { CertificateDirectory(root: $0) })
    }

    /// Returns a cleanly-terminated link to the pool, closing it when the pool is
    /// already at its high water mark.
    func release(_ link: Link) async {
        guard !closed, link.isActive, idleLinks.count < config.poolHighWater else {
            await link.close()
            return
        }
        idleLinks.append(link)
    }

    /// Discards a link that was abandoned mid-stream.
    ///
    /// Synapse closes rather than draining, and so do we: reading an unbounded Storm
    /// result set to recycle a socket costs far more than opening a new one.
    func discard(_ link: Link) async {
        await link.close()
    }

    private func startCulling() {
        let interval = config.poolCullInterval
        cullTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.cullOneLink()
            }
        }
    }

    /// Closes at most one link per interval while above the high water mark,
    /// matching Synapse's cull rate.
    private func cullOneLink() async {
        guard !closed, idleLinks.count > config.poolHighWater else { return }
        let link = idleLinks.removeFirst()
        await link.close()
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        cullTask?.cancel()
        for link in idleLinks { await link.close() }
        idleLinks.removeAll()
        await mainLink.close()
        if ownsGroup { try? await group.shutdownGracefully() }
    }
}

extension TimeAmount {
    init(_ duration: Duration) {
        let components = duration.components
        self = .nanoseconds(components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000)
    }
}
