import Foundation
import Logging
import Msgpack
import NIOCore
import NIOPosix
import TelepathTLS

public struct Config: Sendable {
    /// Deadline for establishing the TCP connection. It does **not** cover the
    /// Telepath handshake, which is server-side work of a different order.
    public var connectTimeout: Duration = .seconds(10)

    /// Deadline for the `tele:syn` exchange. Nil, the default, means wait
    /// indefinitely, matching Synapse, which sets no handshake deadline.
    ///
    /// Kept separate from ``connectTimeout`` deliberately: a cold cell can take
    /// far longer to authenticate and assemble its `sharinfo` than to accept a
    /// socket, and reusing the connect budget here made connecting to a
    /// just-started Cortex fail. Cancelling the task also unblocks a stalled
    /// connect, so an unbounded default is not a hang with no way out.
    public var handshakeTimeout: Duration?
    /// Client-side deadline for a single wait on a server message. Nil means wait
    /// indefinitely, matching Synapse, and is the default.
    ///
    /// For a unary call this bounds the whole call, since it is one wait. For a
    /// generator it bounds the gap *between* yields rather than the total duration,
    /// because a legitimate Storm query can run for hours; it is a liveness check,
    /// not a budget. A query that is silent for longer than this fails, so size it
    /// against the quietest query you expect, or leave it nil and cancel the task
    /// instead.
    ///
    /// A timed-out link is closed rather than pooled: the reply may still arrive,
    /// and a recycled link would hand it to the next call.
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
    /// Session liveness, fanned out through ``state``. Held here so the proxy owns
    /// it; deliberately never the other way round.
    private nonisolated let stateBroadcaster = ProxyStateBroadcaster()
    private var cullTask: Task<Void, Never>?
    private var mainLinkTask: Task<Void, Never>?
    /// Links being opened in the background, counted so a burst of calls cannot
    /// stack up an unbounded number of connection attempts.
    private var pendingFills = 0
    /// The in-flight background top-ups, held so `close()` can wait for them.
    /// Keyed so each removes only itself when it finishes.
    private var fillTasks: [Int: Task<Void, Never>] = [:]
    private var nextFillID = 0

    /// The session iden from the handshake. Pool links skip the handshake entirely,
    /// so this value is the only thing binding them to an authenticated session.
    public let sessionIden: String
    public let shareInfo: ShareInfo
    public let features: [String: Int]
    public let protocolVersion: [Int]

    public var methods: [String: MethodInfo] { shareInfo.methods }

    /// Idle links currently pooled. Exposed for tests and diagnostics.
    public var idleLinkCount: Int { idleLinks.count }

    /// The per-message deadline, in NIO's units. Nil means wait indefinitely.
    var callTimeoutAmount: TimeAmount? { config.callTimeout.map(TimeAmount.init) }
    public var serverVersion: [Int]? { shareInfo.synapseVersion }

    /// Session liveness, as it changes.
    ///
    /// Yields ``State/connected`` immediately, then ``State/disconnected(_:)`` once
    /// the main link drops, then finishes. Finishes without a `disconnected` when
    /// the proxy is closed, since closing is not a failure. Each call returns an
    /// independent stream; an observer arriving after the session ended is told at
    /// once rather than waiting for an event that cannot come.
    ///
    /// The proxy does **not** re-handshake, by decision rather than omission: a
    /// silent re-handshake loses server-side share state the caller still holds
    /// references to, and loops on `AuthDeny` after a credential rotation. This is
    /// the signal that lets a caller reconnect on its own terms, which means
    /// opening a new `Proxy` — the only construction that honestly rebuilds the
    /// session, the pool, and the caller's shares together.
    ///
    /// Holding the stream does not keep the proxy alive, and neither does never
    /// draining it. A slow observer sees only the latest state; it cannot stall the
    /// proxy or grow a buffer behind it.
    public nonisolated var state: AsyncStream<State> { stateBroadcaster.makeStream() }

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
        // Tracked so a handshake failure closes the socket. Shutting down the event
        // loop group only cleans up when the group is ours, which leaked a live
        // channel per attempt for callers supplying their own.
        var connected: Link?
        do {
            let link = try await Link.connect(
                to: url,
                group: eventLoopGroup,
                timeout: TimeAmount(config.connectTimeout),
                certificateDirectory: config.certificateDirectory.map { CertificateDirectory(root: $0) })
            connected = link
            let result = try await Self.handshake(
                on: link, url: url, timeout: config.handshakeTimeout.map(TimeAmount.init))
            let proxy = Proxy(url: url, config: config, group: eventLoopGroup, ownsGroup: ownsGroup,
                              mainLink: link, sessionIden: result.session, shareInfo: result.shareInfo,
                              features: result.features, protocolVersion: result.version)
            await proxy.startCulling()
            await proxy.startMainLinkReader()
            return proxy
        } catch {
            await connected?.close()
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

    private static func handshake(
        on link: Link,
        url: TelepathURL,
        timeout: TimeAmount?
    ) async throws -> HandshakeResult {
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
        ]), timeout: timeout)

        // Bounded by handshakeTimeout, which is nil by default: neither the connect
        // budget nor the call deadline governs this exchange.
        let message = try Message(try await link.receiveRequired(timeout: timeout))
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
                features[name] = Self.featureVersion(value)
            }
        }

        return HandshakeResult(
            session: session,
            shareInfo: ShareInfo(message["sharinfo"] ?? .null),
            features: features,
            version: version
        )
    }

    /// A feature's advertised version.
    ///
    /// 2.x advertises integers. 3.0 dropped the legacy feature set entirely — the
    /// capabilities became unconditional — and its one remaining feature,
    /// `stormservice`, carries the dotted string `"1.0.0"`. Reading only integers
    /// scored that as 0, so `hasFeature("stormservice")` denied a feature the
    /// server does advertise.
    private static func featureVersion(_ value: MsgpackValue) -> Int {
        if let number = value.intValue { return Int(number) }
        if let text = value.stringValue, let major = SynapseVersionParsing.parse(text)?.first {
            return major
        }
        return value.boolValue == true ? 1 : 0
    }

    /// Feature gating: `features[name]` is a version integer, not a flag.
    ///
    /// Note that a Synapse 3.0 server advertises almost nothing here, so a false
    /// answer means "not advertised", never "not supported". This client gates on
    /// `sess` rather than on `features` for exactly that reason.
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
            try await link.send(Self.taskInit(method, args, kwargs, share: share, session: sessionIden),
                                timeout: callTimeoutAmount)
            let message = try Message(try await link.receiveRequired(timeout: callTimeoutAmount))

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

    /// Issues a unary call and decodes its result.
    public func call<T: Decodable>(
        _ method: String,
        _ args: [MsgpackValue] = [],
        kwargs: [String: MsgpackValue] = [:],
        share: String? = nil,
        returning type: T.Type
    ) async throws -> T {
        let value = try await call(method, args, kwargs: kwargs, share: share)
        return try MsgpackDecoder().decode(type, from: value)
    }

    /// Issues a unary call with `Encodable` arguments, so callers can pass Swift
    /// values rather than hand-building `MsgpackValue` trees.
    public func call(
        _ method: String,
        encoding args: [any Encodable],
        kwargs: [String: any Encodable] = [:],
        share: String? = nil
    ) async throws -> MsgpackValue {
        let encoder = MsgpackEncoder()
        return try await call(
            method,
            try args.map { try encoder.encode($0) },
            kwargs: try kwargs.mapValues { try encoder.encode($0) },
            share: share
        )
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

    /// Issues a call expected to return a dynamically shared object.
    ///
    /// Unlike a generator, the link is free the moment the reply lands: the share
    /// is addressed by iden on later calls rather than by holding a connection.
    public func callForShare(
        _ method: String,
        _ args: [MsgpackValue] = [],
        kwargs: [String: MsgpackValue] = [:],
        share: String? = nil
    ) async throws -> Share {
        let link = try await takeLink()
        do {
            try await link.send(Self.taskInit(method, args, kwargs, share: share, session: sessionIden),
                                timeout: callTimeoutAmount)
            let message = try Message(try await link.receiveRequired(timeout: callTimeoutAmount))

            switch message.name {
            case "t2:share":
                guard let iden = message["iden"]?.stringValue else {
                    throw TelepathError.protocolViolation("t2:share carried no iden")
                }
                await release(link)
                return Share(proxy: self, iden: iden,
                             shareInfo: ShareInfo(message["sharinfo"] ?? .null))

            case "t2:fini":
                guard let retn = message["retn"] else {
                    throw TelepathError.protocolViolation("t2:fini carried no retn")
                }
                _ = try Retn.unwrap(retn)
                await release(link)
                throw TelepathError.protocolViolation(
                    "'\(method)' returned a value, not a share; call call(_:) instead")

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

    /// Releases a share. `share:fini` travels on the main link, never a pool link.
    func finishShare(_ iden: String) async {
        guard !closed else { return }
        try? await mainLink.send(.array([
            .string("share:fini"),
            .map([.string("share"): .string(iden)]),
        ]), timeout: callTimeoutAmount)
    }

    /// Opens a generator call and hands the caller its exclusively-owned link.
    func beginStream(
        method: String,
        args: [MsgpackValue],
        kwargs: [String: MsgpackValue],
        share: String?
    ) async throws -> (link: Link, timeout: TimeAmount?) {
        let link = try await takeLink()
        do {
            try await link.send(Self.taskInit(method, args, kwargs, share: share, session: sessionIden),
                                timeout: callTimeoutAmount)
            let message = try Message(try await link.receiveRequired(timeout: callTimeoutAmount))
            switch message.name {
            case "t2:genr":
                // Handed out with the deadline so each yield is bounded too.
                return (link, callTimeoutAmount)
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
        defer { refillPool() }
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

    /// Opens replacements in the background when idle links fall below the low
    /// water mark, matching Synapse.
    ///
    /// Deliberately reactive rather than eager: filling only after a link has been
    /// taken means a proxy that is never called never opens spare connections,
    /// which matters for a client on a metered link. The default marks are
    /// Synapse's and are configurable precisely because they suit a server better
    /// than a phone.
    private func refillPool() {
        guard !closed else { return }
        let wanted = config.poolLowWater - (idleLinks.count + pendingFills)
        guard wanted > 0 else { return }

        pendingFills += wanted
        for _ in 0..<wanted {
            let id = nextFillID
            nextFillID += 1
            fillTasks[id] = Task { [weak self] in
                guard let self else { return }
                await self.fillOneLink(id: id)
            }
        }
    }

    /// Opens one spare link. Failures are swallowed: a background top-up must not
    /// surface an error to a caller who never asked for this connection.
    private func fillOneLink(id: Int) async {
        defer {
            pendingFills -= 1
            fillTasks[id] = nil
        }
        guard !closed else { return }
        guard let link = try? await Link.connect(
            to: url,
            group: group,
            timeout: TimeAmount(config.connectTimeout),
            certificateDirectory: config.certificateDirectory.map { CertificateDirectory(root: $0) })
        else { return }

        // The proxy may have closed while this was connecting.
        guard !closed, idleLinks.count < config.poolHighWater else {
            await link.close()
            return
        }
        idleLinks.append(link)
    }

    /// Consumes the main link.
    ///
    /// Nothing read it before, which was survivable only because a task-v2 server
    /// sends nothing there — but the link disables autoRead, so an unread main link
    /// would eventually stall a server that did write to it. Shares make that real.
    ///
    /// Unknown message names are logged and dropped rather than treated as errors:
    /// spec 3.4 is explicit that an unrecognised main-link message must not close
    /// the connection, and new ones appear between Synapse releases.
    private func startMainLinkReader() {
        mainLinkTask = Task { [weak self] in
            guard let self else { return }
            await self.readMainLink()
        }
    }

    private func readMainLink() async {
        while !closed {
            let value: MsgpackValue?
            do {
                value = try await mainLink.receive()
            } catch {
                // The main link died; the session is gone with it. Cancellation is
                // close() doing its job, not a disconnect, and close() finishes the
                // stream itself.
                config.logger.debug("main link closed: \(error)")
                if !closed { stateBroadcaster.disconnected(error) }
                return
            }
            // A clean end of stream is still the end of the session: the server hung
            // up. It reads as orderly, so it is easy to mistake for nothing having
            // happened, which is exactly why it has to be reported.
            guard let value else {
                if !closed { stateBroadcaster.disconnected(TelepathError.connectionClosed) }
                return
            }

            guard let message = try? Message(value) else {
                config.logger.warning("unparseable message on the main link")
                continue
            }
            switch message.name {
            case "share:data", "share:fini":
                // Task v1 share traffic. Nothing consumes it yet; dropping it is
                // correct for a task-v2-only client.
                config.logger.debug("main link: \(message.name)")
            default:
                config.logger.info("ignoring unknown main link message: \(message.name)")
            }
        }
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

        // Every background task must finish before the event loop group goes away.
        // Cancelling is not enough: a top-up already inside `Link.connect`, or a
        // cull already inside `Link.close`, is holding the group, and shutting it
        // down underneath one means bootstrapping or closing on a dead event loop.
        // SwiftNIO reports that as an error today and has said it will become a
        // forced crash. Awaiting is safe because the actor is released at each
        // suspension, so the tasks can still make progress.
        let culler = cullTask
        let reader = mainLinkTask
        cullTask = nil
        mainLinkTask = nil
        let fills = Array(fillTasks.values)
        fillTasks.removeAll()

        culler?.cancel()
        reader?.cancel()
        for task in fills { task.cancel() }
        await culler?.value
        await reader?.value
        for task in fills { await task.value }

        for link in idleLinks { await link.close() }
        idleLinks.removeAll()
        await mainLink.close()
        if ownsGroup { try? await group.shutdownGracefully() }
        stateBroadcaster.finish()
    }
}

extension TimeAmount {
    init(_ duration: Duration) {
        let components = duration.components
        self = .nanoseconds(components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000)
    }
}
