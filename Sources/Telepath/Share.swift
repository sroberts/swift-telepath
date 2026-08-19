import Msgpack

/// A dynamically shared object returned by a `t2:share` reply.
///
/// The server hands back an iden that addresses a server-side object; calls on it
/// are ordinary `t2:init` messages carrying that iden as `name`. Teardown is the
/// part that is easy to get wrong: `share:fini` goes on the proxy's **main** link,
/// not on a pool link.
public actor Share {
    /// Closed state lives in a reference the deinit can read, since an actor's
    /// deinit cannot touch isolated state.
    final class State: @unchecked Sendable {
        var closed = false
    }

    private let proxy: Proxy
    private let state: State

    // Immutable and safe to read from anywhere; the actor exists to serialise
    // close(), not to guard these.
    public nonisolated let iden: String
    public nonisolated let shareInfo: ShareInfo

    /// Method metadata for the shared object, in the same shape as the proxy's.
    public nonisolated var methods: [String: MethodInfo] { shareInfo.methods }

    init(proxy: Proxy, iden: String, shareInfo: ShareInfo) {
        self.proxy = proxy
        self.iden = iden
        self.shareInfo = shareInfo
        self.state = State()
    }

    public nonisolated var isClosed: Bool { state.closed }

    public func call(
        _ method: String,
        _ args: [MsgpackValue] = [],
        kwargs: [String: MsgpackValue] = [:]
    ) async throws -> MsgpackValue {
        guard !state.closed else { throw TelepathError.shareClosed(iden) }
        return try await proxy.call(method, args, kwargs: kwargs, share: iden)
    }

    public func call<T: Decodable>(
        _ method: String,
        _ args: [MsgpackValue] = [],
        kwargs: [String: MsgpackValue] = [:],
        returning type: T.Type
    ) async throws -> T {
        try MsgpackDecoder().decode(type, from: try await call(method, args, kwargs: kwargs))
    }

    public nonisolated func stream(
        _ method: String,
        _ args: [MsgpackValue] = [],
        kwargs: [String: MsgpackValue] = [:]
    ) -> TelepathStream {
        proxy.stream(method, args, kwargs: kwargs, share: iden)
    }

    /// Releases the server-side object. Idempotent.
    public func close() async {
        guard !state.closed else { return }
        state.closed = true
        await proxy.finishShare(iden)
    }

    deinit {
        // A backstop, not the contract: actors give no deterministic deinit
        // ordering, so callers should still close explicitly.
        guard !state.closed else { return }
        state.closed = true
        let proxy = self.proxy
        let iden = self.iden
        Task { await proxy.finishShare(iden) }
    }
}
