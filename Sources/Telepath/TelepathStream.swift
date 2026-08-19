import Msgpack
import NIOCore

/// An in-progress generator call.
///
/// The call is not issued until the first iteration, matching Synapse's `GenrIter`,
/// so building a stream costs nothing. From `t2:init` until a terminator, the
/// stream exclusively owns one pool link.
public struct TelepathStream: AsyncSequence, Sendable {
    public typealias Element = MsgpackValue

    let proxy: Proxy
    let method: String
    let args: [MsgpackValue]
    let kwargs: [String: MsgpackValue]
    let share: String?

    public func makeAsyncIterator() -> Iterator {
        Iterator(proxy: proxy, method: method, args: args, kwargs: kwargs, share: share)
    }

    /// Collects the whole stream. Convenient for bounded results and a footgun for
    /// unbounded ones — prefer iterating a large Storm query.
    public func collect() async throws -> [MsgpackValue] {
        var items: [MsgpackValue] = []
        for try await item in self { items.append(item) }
        return items
    }

    /// Decodes each element, preserving laziness: nothing is decoded until it is
    /// iterated, so a large stream stays bounded in memory.
    public func decode<T: Decodable>(_ type: T.Type) -> DecodedStream<T> {
        DecodedStream(base: self, decoder: MsgpackDecoder())
    }

    /// A class rather than a struct so that abandoning a stream early has a
    /// deterministic hook: `deinit` closes the link instead of leaking it.
    public final class Iterator: AsyncIteratorProtocol {
        private enum State {
            case pending
            /// The deadline travels with the link so every yield is bounded, not
            /// just the call that opened the stream.
            case streaming(Link, TimeAmount?)
            case finished
        }

        private let proxy: Proxy
        private let method: String
        private let args: [MsgpackValue]
        private let kwargs: [String: MsgpackValue]
        private let share: String?
        private var state: State = .pending

        init(proxy: Proxy, method: String, args: [MsgpackValue],
             kwargs: [String: MsgpackValue], share: String?) {
            self.proxy = proxy
            self.method = method
            self.args = args
            self.kwargs = kwargs
            self.share = share
        }

        public func next() async throws -> MsgpackValue? {
            let link: Link
            let timeout: TimeAmount?
            switch state {
            case .finished:
                return nil
            case .pending:
                (link, timeout) = try await proxy.beginStream(
                    method: method, args: args, kwargs: kwargs, share: share)
                state = .streaming(link, timeout)
            case .streaming(let existing, let existingTimeout):
                link = existing
                timeout = existingTimeout
            }

            let message: Message
            do {
                message = try Message(try await link.receiveRequired(timeout: timeout))
            } catch {
                state = .finished
                await proxy.discard(link)
                throw error
            }

            // After t2:genr, anything but t2:yield is a protocol violation. There is
            // no resync point on an unframed stream, so the link dies with the stream.
            guard message.name == "t2:yield" else {
                state = .finished
                await proxy.discard(link)
                throw TelepathError.protocolViolation(
                    "expected t2:yield during a generator, got \(message.name)")
            }

            guard let retn = message["retn"] else {
                state = .finished
                await proxy.discard(link)
                throw TelepathError.protocolViolation("t2:yield carried no retn")
            }

            // A null retn is the normal end of stream.
            if retn.isNull {
                state = .finished
                await proxy.release(link)
                return nil
            }

            do {
                return try Retn.unwrap(retn)
            } catch {
                // An exception mid-stream also terminates it cleanly, so the link is
                // still reusable.
                state = .finished
                await proxy.release(link)
                throw error
            }
        }

        deinit {
            // Early abandonment: Synapse closes the link rather than draining it,
            // and draining an unbounded query to recycle a socket is worse than
            // opening a new one.
            if case .streaming(let link, _) = state {
                let proxy = self.proxy
                Task { await proxy.discard(link) }
            }
        }
    }
}


/// A ``TelepathStream`` whose elements are decoded into a `Decodable` type.
public struct DecodedStream<T: Decodable>: AsyncSequence, Sendable {
    public typealias Element = T

    let base: TelepathStream
    let decoder: MsgpackDecoder

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator(), decoder: decoder)
    }

    public func collect() async throws -> [T] {
        var items: [T] = []
        for try await item in self { items.append(item) }
        return items
    }

    public struct Iterator: AsyncIteratorProtocol {
        var base: TelepathStream.Iterator
        let decoder: MsgpackDecoder

        public mutating func next() async throws -> T? {
            guard let value = try await base.next() else { return nil }
            return try decoder.decode(T.self, from: value)
        }
    }
}
