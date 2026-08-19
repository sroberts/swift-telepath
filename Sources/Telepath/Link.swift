import Msgpack
import NIOCore
import NIOPosix
import NIOSSL
import TelepathTLS

/// One connection carrying an unframed msgpack stream.
///
/// A link is exclusively owned by one caller at a time — the handshake, or a
/// single call from `t2:init` until its terminator — so ``receive()`` is
/// deliberately not serialised beyond the event loop. Concurrent receivers on the
/// same link would interleave a call's messages and are a programming error.
final class Link: Sendable {
    private let channel: Channel
    private let handler: LinkHandler

    private init(channel: Channel, handler: LinkHandler) {
        self.channel = channel
        self.handler = handler
    }

    var isActive: Bool { channel.isActive }

    static func connect(
        to url: TelepathURL,
        group: any EventLoopGroup,
        timeout: TimeAmount,
        certificateDirectory: CertificateDirectory? = nil
    ) async throws -> Link {
        let handler = LinkHandler()

        // Built once, off the event loop: reading certificates from disk must not
        // happen inside the channel initializer.
        let tls: TLSSetup? = url.scheme == .ssl
            ? try TLSSetup(url: url, certificateDirectory: certificateDirectory)
            : nil

        // Resolved before the handshake promise exists: a throw here would
        // otherwise abandon the promise, and NIO traps on a leaked one.
        enum Endpoint {
            case network(host: String, port: Int)
            case socket(path: String)
        }
        let endpoint: Endpoint
        switch url.scheme {
        case .tcp, .ssl:
            guard let host = url.host else {
                throw TelepathError.invalidURL("\(url)", reason: "missing host")
            }
            endpoint = .network(host: host, port: url.port)
        case .unix, .cell:
            guard let path = url.path else {
                throw TelepathError.invalidURL("\(url)", reason: "missing socket path")
            }
            endpoint = .socket(path: path)
        }

        // Fulfilled when the TLS handshake completes or fails, so the caller sees
        // the real error instead of a closed-channel write failure.
        let handshakePromise: EventLoopPromise<Void>? =
            tls != nil ? group.next().makePromise(of: Void.self) : nil

        let bootstrap = ClientBootstrap(group: group)
            // Reads are issued explicitly so an unconsumed stream applies
            // backpressure to the server instead of filling a userspace buffer.
            .channelOption(.autoRead, value: false)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                do {
                    if let tls, let handshakePromise {
                        try channel.pipeline.syncOperations.addHandlers(
                            tls.handlers(handshake: handshakePromise, timeout: timeout))
                    }
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel: Channel
        do {
            switch endpoint {
            case .network(let host, let port):
                channel = try await bootstrap.connect(host: host, port: port).get()
            case .socket(let path):
                channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
            }
        } catch {
            // A channel that never went active never fires channelInactive, so the
            // handler cannot settle the promise. Left alone it is leaked, and NIO
            // traps on a leaked promise in debug builds — a refused connection
            // would take the process down.
            handshakePromise?.fail(error)
            throw error
        }
        if let handshakePromise {
            // The link disables autoRead so an unconsumed stream applies backpressure.
            // A TLS handshake, though, needs to read before anyone has asked for a
            // message, and NIOSSL only re-reads once a read is already pending — so
            // without this kick the handshake stalls on the first round trip. After
            // it completes, normal demand-driven reads take over.
            channel.read()
            do {
                try await handshakePromise.futureResult.get()
            } catch {
                try? await channel.close()
                throw error
            }
        }
        return Link(channel: channel, handler: handler)
    }

    /// Writes a message, bounded by `timeout`.
    ///
    /// The read side is not the only place a call can stall: a peer that accepts
    /// the connection and stops reading fills the TCP window, and an unbounded
    /// write would then block a call that has a deadline set.
    func send(_ value: MsgpackValue, timeout: TimeAmount? = nil) async throws {
        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeBytes(MsgpackPacker.encode(value))
        let write: EventLoopFuture<Void> = channel.writeAndFlush(buffer)
        guard let timeout else {
            return try await write.get()
        }
        try await write.withDeadline(timeout, on: channel.eventLoop,
                                     message: "sending a request").get()
    }

    /// The next message, or nil at a clean end of stream.
    ///
    /// `timeout` bounds this single wait, not a whole conversation. A caller that
    /// times out — or cancels — must close the link rather than pool it: the reply
    /// may still arrive, and a recycled link would deliver it to the next call.
    ///
    /// Cancellation is honoured. A bare `withCheckedThrowingContinuation` ignores
    /// it, which left a cancelled call suspended until the server replied or the
    /// socket dropped.
    func receive(timeout: TimeAmount? = nil) async throws -> MsgpackValue? {
        let token = WaiterToken()
        let eventLoop = channel.eventLoop
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                eventLoop.execute { [handler] in
                    handler.take(continuation, token: token, timeout: timeout, on: eventLoop)
                }
            }
        } onCancel: {
            eventLoop.execute { [handler] in
                handler.cancel(token: token)
            }
        }
    }

    /// The next message, treating end of stream as a failure. Used wherever the
    /// protocol guarantees a reply.
    func receiveRequired(timeout: TimeAmount? = nil) async throws -> MsgpackValue {
        guard let value = try await receive(timeout: timeout) else {
            throw TelepathError.connectionClosed
        }
        return value
    }

    func close() async {
        try? await channel.close().get()
    }
}

/// Identity for one pending `receive`, so a deadline or a cancellation can find
/// exactly its own waiter. State is confined to the channel's event loop.
final class WaiterToken: @unchecked Sendable {
    var isCancelled = false
}

/// Guards the race between a deadline and the work it bounds. Event-loop confined.
final class DeadlineFlag: @unchecked Sendable {
    var value = false
}

extension EventLoopFuture {
    /// Fails with `TelepathError.timedOut` if the future has not completed in time.
    ///
    /// Completion is guarded by a flag so the race between the timer and the
    /// future cannot complete the promise twice, which would trap.
    func withDeadline(
        _ timeout: TimeAmount,
        on eventLoop: EventLoop,
        message: String
    ) -> EventLoopFuture<Value> {
        let settled = DeadlineFlag()
        let promise = eventLoop.makePromise(of: Value.self)

        let scheduled = eventLoop.scheduleTask(in: timeout) {
            guard !settled.value else { return }
            settled.value = true
            promise.fail(TelepathError.timedOut(message))
        }
        hop(to: eventLoop).whenComplete { result in
            scheduled.cancel()
            guard !settled.value else { return }
            settled.value = true
            promise.completeWith(result)
        }
        return promise.futureResult
    }
}

/// Resolves a URL's TLS parameters into the handlers a connection needs.
///
/// Synapse's rules, reproduced exactly because a conventional TLS client cannot
/// reach real deployments: hostname verification is off in both modes; a `certhash`
/// pins the peer and disables chain trust entirely; otherwise the CA chain is
/// verified and the certificate's **common name** is compared to the hostname.
private struct TLSSetup {
    let context: NIOSSLContext
    let policy: TLSPolicy
    let expectedHostname: String?

    init(url: TelepathURL, certificateDirectory: CertificateDirectory?) throws {
        let hostname = url.expectedHostname
        self.expectedHostname = hostname

        if let certHash = url.certHash {
            self.policy = .pinnedFingerprint(certHash)
        } else {
            guard let hostname else {
                throw TelepathError.invalidURL("\(url)", reason: "ssl:// requires a hostname to verify")
            }
            self.policy = .certificateAuthority(expectedHostname: hostname)
        }

        // Precedence: the URL's certdir, then the caller's, then Synapse's default.
        let directory = CertificateDirectory(path: url.certDirectory)
            ?? certificateDirectory
            ?? CertificateDirectory(root: CertificateDirectory.defaultRoot)

        // A user supplied without a password authenticates by client certificate,
        // which Synapse resolves as `{user}@{hostname}`.
        var clientCertificateName = url.certName
        if clientCertificateName == nil, let user = url.user, url.password == nil, let hostname {
            clientCertificateName = CertificateDirectory.clientCertificateName(user: user, hostname: hostname)
        }

        self.context = try TelepathTLS.makeContext(
            policy: policy,
            certificateDirectory: directory,
            clientCertificateName: clientCertificateName
        )
    }

    func handlers(handshake: EventLoopPromise<Void>, timeout: TimeAmount) throws -> [ChannelHandler] {
        let failure = TLSVerificationFailure()
        // Pinning already identifies the peer exactly, so the name check applies
        // only to the CA path.
        var expectedCommonName: String?
        if case .certificateAuthority(let hostname) = policy {
            expectedCommonName = hostname
        }
        return [
            try TelepathTLS.makeHandler(context: context, policy: policy,
                                        serverHostname: expectedHostname, failure: failure),
            TLSHandshakeHandler(expectedHostname: expectedCommonName, promise: handshake,
                                failure: failure, timeout: timeout),
        ]
    }
}

/// Decodes the inbound byte stream and hands messages to whoever is waiting.
///
/// All state is confined to the channel's event loop; `@unchecked Sendable` is the
/// standard NIO handler contract, not a shortcut.
private final class LinkHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    /// A pending `receive`, with the deadline that will fail it.
    private struct Waiter {
        let token: WaiterToken
        let continuation: CheckedContinuation<MsgpackValue?, Error>
        var deadline: Scheduled<Void>?
    }

    private var unpacker = MsgpackStreamUnpacker()
    private var ready: [MsgpackValue] = []
    private var waiters: [Waiter] = []
    private var context: ChannelHandlerContext?
    private var failure: (any Error)?
    private var atEOF = false

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    /// Called on the event loop. Satisfies the waiter immediately when a message is
    /// already decoded, otherwise registers it and asks the channel for more bytes.
    func take(
        _ continuation: CheckedContinuation<MsgpackValue?, Error>,
        token: WaiterToken,
        timeout: TimeAmount?,
        on eventLoop: EventLoop
    ) {
        // Cancellation can win the race to the event loop, arriving before the
        // waiter is even registered.
        if token.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if !ready.isEmpty {
            continuation.resume(returning: ready.removeFirst())
            return
        }
        if let failure {
            continuation.resume(throwing: failure)
            return
        }
        if atEOF {
            continuation.resume(returning: nil)
            return
        }

        var waiter = Waiter(token: token, continuation: continuation, deadline: nil)
        // Scheduled on the event loop rather than the handler context: a nil
        // context would otherwise mean a configured timeout is silently dropped
        // and the caller waits forever.
        if let timeout {
            waiter.deadline = eventLoop.scheduleTask(in: timeout) { [weak self] in
                self?.expire(token)
            }
        }
        waiters.append(waiter)
        context?.read()
    }

    /// Fails one waiter whose deadline elapsed, leaving any others alone.
    private func expire(_ token: WaiterToken) {
        guard let index = waiters.firstIndex(where: { $0.token === token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.deadline?.cancel()
        waiter.continuation.resume(throwing: TelepathError.timedOut("waiting for a reply"))
    }

    /// Fails one waiter because its task was cancelled.
    func cancel(token: WaiterToken) {
        token.isCancelled = true
        guard let index = waiters.firstIndex(where: { $0.token === token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.deadline?.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        unpacker.append(bytes)
        do {
            while let value = try unpacker.next() {
                ready.append(value)
            }
        } catch {
            // A framing error on an unframed stream is unrecoverable: there is no
            // resync point, so the link must die rather than emit garbage.
            fail(context: context, error: error)
            return
        }
        deliver()
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        // Still someone waiting and nothing decoded: the value spans reads.
        if !waiters.isEmpty && ready.isEmpty {
            context.read()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        atEOF = true
        deliver()
        for waiter in waiters {
            waiter.deadline?.cancel()
            waiter.continuation.resume(returning: nil)
        }
        waiters.removeAll()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(context: context, error: error)
    }

    private func deliver() {
        while !waiters.isEmpty && !ready.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.deadline?.cancel()
            waiter.continuation.resume(returning: ready.removeFirst())
        }
    }

    private func fail(context: ChannelHandlerContext, error: any Error) {
        failure = error
        for waiter in waiters {
            waiter.deadline?.cancel()
            waiter.continuation.resume(throwing: error)
        }
        waiters.removeAll()
        context.close(promise: nil)
    }
}
