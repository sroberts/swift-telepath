import NIOConcurrencyHelpers

extension Proxy {
    /// Whether the proxy's session is still alive.
    ///
    /// A session ends when the main link drops, because the session iden dies with
    /// it and every pool link is bound to that iden. Individual calls failing —
    /// timing out, being cancelled, hitting a remote error — do not end it.
    public enum State: Sendable {
        case connected
        /// The main link dropped, carrying whatever ended it. The proxy does not
        /// re-handshake; see ``Proxy/state`` for why, and what to do instead.
        case disconnected(any Error)
    }
}

/// Fans ``Proxy/State`` out to however many observers exist, without any of them
/// reaching back to the proxy.
///
/// This is a separate object rather than actor state for one reason: an
/// `AsyncStream` retains its `onTermination` handler, so a handler that captured
/// the proxy would keep an actor — and the event loop group it owns — alive for as
/// long as anyone held the stream, including forever if they simply never drained
/// it. Holding the broadcaster instead keeps that cycle from existing. The proxy
/// owns this; this owns nothing.
final class ProxyStateBroadcaster: Sendable {
    private struct Storage {
        var observers: [Int: AsyncStream<Proxy.State>.Continuation] = [:]
        var nextID = 0
        /// Set once the session ends, so an observer arriving afterwards is told
        /// immediately rather than waiting for an event that can never come.
        var ended: (any Error)?
        var finished = false
    }

    private let storage = NIOLockedValueBox(Storage())

    /// A new observer's stream.
    ///
    /// Buffering is `bufferingNewest(2)`, which is the whole lifetime: `connected`
    /// at subscription and at most one `disconnected`. A bound of 1 looked tidier
    /// and was wrong — `connected` is yielded eagerly at subscription, so a link
    /// dropping before the consumer's first `next()` would evict it and break the
    /// documented "connected, then disconnected" contract. Two is still O(1), so a
    /// consumer that stops iterating still cannot stall the proxy or grow a buffer
    /// behind it.
    func makeStream() -> AsyncStream<Proxy.State> {
        AsyncStream(Proxy.State.self, bufferingPolicy: .bufferingNewest(2)) { continuation in
            let id: Int? = storage.withLockedValue { storage in
                if storage.finished {
                    continuation.finish()
                    return nil
                }
                if let ended = storage.ended {
                    continuation.yield(.disconnected(ended))
                    continuation.finish()
                    return nil
                }
                continuation.yield(.connected)
                let id = storage.nextID
                storage.nextID += 1
                storage.observers[id] = continuation
                return id
            }
            guard let id else { return }
            continuation.onTermination = { [storage] _ in
                storage.withLockedValue { $0.observers[id] = nil }
            }
        }
    }

    /// Reports the session as ended. The first error wins: what dropped the link is
    /// more informative than whatever failed afterwards because it had.
    func disconnected(_ error: any Error) {
        let observers: [AsyncStream<Proxy.State>.Continuation] = storage.withLockedValue { storage in
            guard !storage.finished, storage.ended == nil else { return [] }
            storage.ended = error
            let observers = Array(storage.observers.values)
            storage.observers.removeAll()
            return observers
        }
        for continuation in observers {
            continuation.yield(.disconnected(error))
            continuation.finish()
        }
    }

    /// Ends every stream because the proxy was closed. Closing is not a failure, so
    /// no `disconnected` is emitted for it.
    func finish() {
        let observers: [AsyncStream<Proxy.State>.Continuation] = storage.withLockedValue { storage in
            storage.finished = true
            let observers = Array(storage.observers.values)
            storage.observers.removeAll()
            return observers
        }
        for continuation in observers {
            continuation.finish()
        }
    }

    /// Live observer count. Exists so tests can prove termination deregisters
    /// rather than accumulating continuations for the proxy's lifetime.
    var observerCount: Int {
        storage.withLockedValue { $0.observers.count }
    }
}
