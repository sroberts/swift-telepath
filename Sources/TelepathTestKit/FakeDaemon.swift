import Msgpack
import NIOConcurrencyHelpers
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
    /// Whether this instance bound the socket path, so teardown removes only what
    /// it created.
    private var didBind = false
    private nonisolated let handlerTasks = HandlerTasks()
    public let socketPath: String

    /// A `unix://` URL addressing this daemon.
    ///
    /// Nonisolated because it derives only from `socketPath`, which is a `let`:
    /// making callers await an address that cannot change is friction with no
    /// safety behind it.
    public nonisolated var url: String { "unix://\(socketPath)" }

    public init() {
        let unique = "\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0..<UInt32.max))"
        // Unix socket paths are length-limited; /tmp keeps it short.
        self.init(socketPath: "/tmp/telepath-fake-\(unique).sock")
    }

    /// A daemon on a caller-chosen socket path.
    ///
    /// Exists so a test can restart a server at the address a client already knows,
    /// which is the only way to exercise reconnect honestly: a fresh address would
    /// prove the client can dial somewhere new, not that it recovers from a server
    /// coming back.
    public init(socketPath: String) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.socketPath = socketPath
    }

    public static func start(handler: @escaping Handler) async throws -> FakeDaemon {
        let daemon = FakeDaemon()
        try await daemon.listen(handler: handler)
        return daemon
    }

    public static func start(socketPath: String,
                             handler: @escaping Handler) async throws -> FakeDaemon {
        let daemon = FakeDaemon(socketPath: socketPath)
        try await daemon.listen(handler: handler)
        return daemon
    }

    private func listen(handler: @escaping Handler) async throws {
        // With caller-chosen paths, two daemons can be pointed at one address. The
        // old code unlinked unconditionally, so the second silently stole the first
        // one's socket and then the first one's teardown deleted the second's
        // socket file -- leaving a daemon listening on an address that answers
        // connection-refused. Refuse instead: a stale file is fine to clear, a live
        // server is not.
        if FileManager.default.fileExists(atPath: socketPath) {
            if await Self.isListening(at: socketPath, group: group) {
                throw FakeDaemonError.addressInUse(socketPath)
            }
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    ConnectionHandler(handler: handler, tasks: self.handlerTasks))
            }
        channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
        didBind = true
    }

    /// True when something already answers on the path, as opposed to a stale file
    /// left by a daemon that did not clean up.
    private static func isListening(at path: String, group: any EventLoopGroup) async -> Bool {
        guard let channel = try? await ClientBootstrap(group: group)
            .connect(unixDomainSocketPath: path).get() else { return false }
        try? await channel.close().get()
        return true
    }

    public func stop() async {
        try? await channel?.close().get()
        channel = nil
        // Handler chains outlive the messages that started them — a script that
        // sleeps before replying is the whole point of several tests. Shutting the
        // group down underneath one leaves it writing to a dead event loop, which
        // SwiftNIO reports as an error today and has said it will turn into a
        // forced crash. Cancel and await them first so teardown is ordered.
        await handlerTasks.drain()
        try? await group.shutdownGracefully()
        // Only what this instance bound. Removing a path it never owned would
        // unlink a live daemon's socket.
        if didBind {
            didBind = false
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }
}

/// Failures raised by the fake daemon itself.
public enum FakeDaemonError: Error, Sendable, CustomStringConvertible {
    /// Something is already listening on the requested socket path.
    case addressInUse(String)

    public var description: String {
        switch self {
        case .addressInUse(let path):
            return "a daemon is already listening at \(path); stop it before starting another"
        }
    }
}

/// The live per-connection handler chains, so `FakeDaemon.stop()` can wait for
/// them instead of pulling the event loop group out from under them.
private final class HandlerTasks: @unchecked Sendable {
    private let lock = NIOLock()
    private var tasks: [Task<Void, Never>] = []

    func track(_ task: Task<Void, Never>) {
        lock.withLock { tasks.append(task) }
    }

    func drain() async {
        let pending = lock.withLock {
            let snapshot = tasks
            tasks = []
            return snapshot
        }
        for task in pending {
            task.cancel()
            await task.value
        }
    }
}

import Foundation

/// Decodes the inbound msgpack stream and dispatches each message to the handler,
/// serialised per connection so a script sees messages in order.
private final class ConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let handler: FakeDaemon.Handler
    private let tasks: HandlerTasks
    private var unpacker = MsgpackStreamUnpacker()
    private var connection: FakeDaemon.Connection?
    private var queue: Task<Void, Never>?

    init(handler: @escaping FakeDaemon.Handler, tasks: HandlerTasks) {
        self.handler = handler
        self.tasks = tasks
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
        let chain = Task {
            await previous?.value
            for message in messages {
                try? await handler(message, connection)
            }
        }
        queue = chain
        tasks.track(chain)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
