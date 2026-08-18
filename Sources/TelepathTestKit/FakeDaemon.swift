import Msgpack
import NIOCore
import NIOPosix

/// A scriptable Telepath server.
///
/// The integration suite proves the client works against a healthy Cortex. This
/// exists for everything a healthy Cortex will not do on demand: refuse a
/// handshake, claim the wrong protocol version, omit a session iden, die
/// mid-generator, or emit a message the protocol forbids.
///
/// Listens on a unix socket in a temporary directory, so tests never contend for
/// a TCP port.
public actor FakeDaemon {
    /// One message as it appears on the wire: `(name, info)`.
    public struct Message: Sendable {
        public let name: String
        public let info: MsgpackValue

        public subscript(key: String) -> MsgpackValue? { info[key] }

        /// The method name from a `t2:init` todo tuple.
        public var todoMethod: String? { info["todo"]?[0]?.stringValue }
        public var todoArgs: [MsgpackValue] { info["todo"]?[1]?.arrayValue ?? [] }
    }

    /// Handles one inbound message. Called in receive order per connection.
    public typealias Handler = @Sendable (Message, Connection) async throws -> Void

    /// A live connection to the fake daemon.
    public final class Connection: Sendable {
        private let channel: Channel

        init(channel: Channel) { self.channel = channel }

        public func send(_ value: MsgpackValue) async throws {
            var buffer = channel.allocator.buffer(capacity: 256)
            buffer.writeBytes(MsgpackPacker.encode(value))
            try await channel.writeAndFlush(buffer).get()
        }

        public func send(_ name: String, _ info: [MsgpackValue: MsgpackValue]) async throws {
            try await send(.array([.string(name), .map(info)]))
        }

        /// Writes raw bytes, for tests that need malformed or partial framing.
        public func sendRaw(_ bytes: [UInt8]) async throws {
            var buffer = channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            try await channel.writeAndFlush(buffer).get()
        }

        public func close() async {
            try? await channel.close().get()
        }
    }

    private let group: any EventLoopGroup
    private var channel: Channel?
    public let socketPath: String

    /// A `unix://` URL addressing this daemon.
    public var url: String { "unix://\(socketPath)" }

    public init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let unique = "\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0..<UInt32.max))"
        // Unix socket paths are length-limited; /tmp keeps it short.
        self.socketPath = "/tmp/telepath-fake-\(unique).sock"
    }

    public static func start(handler: @escaping Handler) async throws -> FakeDaemon {
        let daemon = FakeDaemon()
        try await daemon.listen(handler: handler)
        return daemon
    }

    private func listen(handler: @escaping Handler) async throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ConnectionHandler(handler: handler))
            }
        channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
    }

    public func stop() async {
        try? await channel?.close().get()
        channel = nil
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}

import Foundation

/// Decodes the inbound msgpack stream and dispatches each message to the handler,
/// serialised per connection so a script sees messages in order.
private final class ConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let handler: FakeDaemon.Handler
    private var unpacker = MsgpackStreamUnpacker()
    private var connection: FakeDaemon.Connection?
    private var queue: Task<Void, Never>?

    init(handler: @escaping FakeDaemon.Handler) {
        self.handler = handler
    }

    func channelActive(context: ChannelHandlerContext) {
        connection = FakeDaemon.Connection(channel: context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes),
              let connection else { return }
        unpacker.append(bytes)

        var messages: [FakeDaemon.Message] = []
        do {
            while let value = try unpacker.next() {
                guard let items = value.arrayValue, items.count == 2,
                      let name = items[0].stringValue else { continue }
                messages.append(FakeDaemon.Message(name: name, info: items[1]))
            }
        } catch {
            context.close(promise: nil)
            return
        }

        guard !messages.isEmpty else { return }
        // Chain onto the previous task so handlers run in message order.
        let previous = queue
        let handler = self.handler
        queue = Task {
            await previous?.value
            for message in messages {
                try? await handler(message, connection)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
