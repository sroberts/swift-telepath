import Foundation
import Msgpack
import Testing
@testable import Telepath

/// End-to-end tests against a live Synapse Cortex.
///
/// Telepath is defined by its implementation, so these are the tests that actually
/// establish conformance — a scripted fake daemon can only replay assumptions.
/// Set TELEPATH_TEST_URL to a running cell (for example
/// `cell:///path/to/cortex00`); the suite is skipped when it is unset.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TELEPATH_TEST_URL"] != nil))
struct IntegrationTests {
    var testURL: String { ProcessInfo.processInfo.environment["TELEPATH_TEST_URL"]! }

    private func withProxy<T>(_ body: (Proxy) async throws -> T) async throws -> T {
        let proxy = try await Proxy.open(testURL)
        do {
            let result = try await body(proxy)
            await proxy.close()
            return result
        } catch {
            await proxy.close()
            throw error
        }
    }

    @Test("handshake yields a session, server version, features and method metadata")
    func handshake() async throws {
        try await withProxy { proxy in
            let session = await proxy.sessionIden
            #expect(session.count == 32, "session iden should be a 32-char hex guid")

            let version = await proxy.serverVersion
            #expect(version?.first == 2)

            // Pool links are bound to the session, and task v2 requires it.
            let features = await proxy.features
            #expect(!features.isEmpty)
            #expect(await proxy.hasFeature("tasks"))

            // 'genr' is the only method-shape metadata the protocol provides.
            let methods = await proxy.methods
            #expect(methods["storm"]?.isGenerator == true)
            #expect(methods["callStorm"]?.isGenerator == false)
            #expect(methods["getCellInfo"]?.isGenerator == false)
        }
    }

    @Test("a unary call returns a decoded result")
    func unaryCall() async throws {
        try await withProxy { proxy in
            let info = try await proxy.call("getCellInfo")
            let version = info["cell"]?["version"]
            #expect(version != nil, "getCellInfo should report a cell version")
            #expect(info["synapse"]?["version"] != nil)
        }
    }

    @Test("callStorm returns a value computed by the server")
    func callStorm() async throws {
        try await withProxy { proxy in
            let result = try await proxy.call("callStorm", [.string("return((2 + 3))"), .map([:])])
            #expect(result.intValue == 5)
        }
    }

    @Test("a generator call streams messages and terminates")
    func generator() async throws {
        try await withProxy { proxy in
            var kinds: [String] = []
            for try await message in proxy.stream("storm", [.string("[ inet:ipv4=1.2.3.4 ]"), .map([:])]) {
                if let kind = message[0]?.stringValue { kinds.append(kind) }
            }
            #expect(kinds.first == "init")
            #expect(kinds.contains("node"))
            #expect(kinds.last == "fini")
        }
    }

    /// A remote exception is a complete, well-formed exchange — not a transport
    /// failure — so it must arrive as TelepathRemoteError with its name intact.
    @Test("a remote exception maps to TelepathRemoteError")
    func remoteError() async throws {
        try await withProxy { proxy in
            await #expect(throws: TelepathRemoteError.self) {
                try await proxy.call("callStorm", [.string("|||not valid storm|||"), .map([:])])
            }
            do {
                _ = try await proxy.call("callStorm", [.string("|||not valid storm|||"), .map([:])])
            } catch let error as TelepathRemoteError {
                #expect(error.kind == .badSyntax)
                #expect(error.mesg != nil)
            }
        }
    }

    @Test("calling a missing method reports NoSuchMeth rather than hanging")
    func noSuchMethod() async throws {
        try await withProxy { proxy in
            do {
                _ = try await proxy.call("thisMethodDoesNotExist")
                Issue.record("expected the call to fail")
            } catch let error as TelepathRemoteError {
                #expect(error.kind == .noSuchMeth)
            }
        }
    }

    /// Every in-flight call owns a link for its whole duration, so concurrency above
    /// the high water mark is the case where pool accounting goes wrong.
    @Test("concurrent calls exceeding the pool high water mark all succeed")
    func concurrencyAboveHighWater() async throws {
        try await withProxy { proxy in
            let count = 24     // 2x the default high water mark of 12
            let results = try await withThrowingTaskGroup(of: Int64.self) { group in
                for i in 0..<count {
                    group.addTask {
                        let value = try await proxy.call(
                            "callStorm", [.string("return((\(i)))"), .map([:])])
                        return value.intValue ?? -1
                    }
                }
                var collected: [Int64] = []
                for try await value in group { collected.append(value) }
                return collected
            }
            #expect(results.sorted() == (0..<Int64(count)).map { $0 })
        }
    }

    /// Synapse closes an abandoned generator's link rather than draining it. The
    /// client must do the same and stay usable afterwards.
    @Test("abandoning a generator early leaves the proxy usable")
    func earlyAbandonment() async throws {
        try await withProxy { proxy in
            for _ in 0..<5 {
                var seen = 0
                // A query that would yield far more than we consume.
                for try await _ in proxy.stream("storm", [.string("[ inet:ipv4=5.5.5.0/24 ]"), .map([:])]) {
                    seen += 1
                    if seen >= 3 { break }
                }
                #expect(seen == 3)
            }
            // The proxy still works after repeated abandonment.
            let result = try await proxy.call("callStorm", [.string("return((99))"), .map([:])])
            #expect(result.intValue == 99)
        }
    }

    @Test("a bad password is reported as AuthDeny during the handshake")
    func authFailure() async throws {
        var url = try TelepathURL(testURL)
        guard url.scheme == .tcp else { return }   // unix/cell sockets auth as root
        url.user = "root"
        url.password = "definitely-not-the-password"
        await #expect(throws: TelepathRemoteError.self) {
            let proxy = try await Proxy.open(url)
            await proxy.close()
        }
    }
}
