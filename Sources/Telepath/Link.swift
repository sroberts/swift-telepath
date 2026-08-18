import Msgpack
import NIOCore
import NIOPosix

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
        timeout: TimeAmount
    ) async throws -> Link {
        let handler = LinkHandler()
        let bootstrap = ClientBootstrap(group: group)
            // Reads are issued explicitly so an unconsumed stream applies
            // backpressure to the server instead of filling a userspace buffer.
            .channelOption(.autoRead, value: false)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        let channel: Channel
        switch url.scheme {
        case .tcp, .ssl:
            guard let host = url.host else {
                throw TelepathError.invalidURL("\(url)", reason: "missing host")
            }
            if url.scheme == .ssl {
                throw TelepathError.unsupportedScheme("ssl", reason: "TLS support is not implemented yet")
            }
            channel = try await bootstrap.connect(host: host, port: url.port).get()
        case .unix, .cell:
            guard let path = url.path else {
                throw TelepathError.invalidURL("\(url)", reason: "missing socket path")
            }
            channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
        }
        return Link(channel: channel, handler: handler)
    }

    func send(_ value: MsgpackValue) async throws {
        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeBytes(MsgpackPacker.encode(value))
        try await channel.writeAndFlush(buffer).get()
    }

    /// The next message, or nil at a clean end of stream.
    func receive() async throws -> MsgpackValue? {
        try await withCheckedThrowingContinuation { continuation in
            channel.eventLoop.execute { [handler] in
                handler.take(continuation)
            }
        }
    }

    /// The next message, treating end of stream as a failure. Used wherever the
    /// protocol guarantees a reply.
    func receiveRequired() async throws -> MsgpackValue {
        guard let value = try await receive() else {
            throw TelepathError.connectionClosed
        }
        return value
    }

    func close() async {
        try? await channel.close().get()
    }
}

/// Decodes the inbound byte stream and hands messages to whoever is waiting.
///
/// All state is confined to the channel's event loop; `@unchecked Sendable` is the
/// standard NIO handler contract, not a shortcut.
private final class LinkHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var unpacker = MsgpackStreamUnpacker()
    private var ready: [MsgpackValue] = []
    private var waiters: [CheckedContinuation<MsgpackValue?, Error>] = []
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
    func take(_ continuation: CheckedContinuation<MsgpackValue?, Error>) {
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
        waiters.append(continuation)
        context?.read()
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
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(context: context, error: error)
    }

    private func deliver() {
        while !waiters.isEmpty && !ready.isEmpty {
            waiters.removeFirst().resume(returning: ready.removeFirst())
        }
    }

    private func fail(context: ChannelHandlerContext, error: any Error) {
        failure = error
        for waiter in waiters { waiter.resume(throwing: error) }
        waiters.removeAll()
        context.close(promise: nil)
    }
}
