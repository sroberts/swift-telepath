import Testing
import TelepathTestKit
@testable import Telepath

/// `FakeDaemon.start(socketPath:)` lets two daemons be aimed at one address, which
/// is a footgun the random-path initialiser never had. These pin the guards that
/// make the collision loud instead of silently destructive.
@Suite struct FakeDaemonAddressTests {
    private static func path() -> String {
        "/tmp/telepath-addr-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    /// The old behaviour unlinked the path unconditionally, so the second daemon
    /// stole the first one's address without a word.
    @Test("starting a second daemon on a live address fails loudly")
    func refusesALiveAddress() async throws {
        let socketPath = Self.path()
        let first = try await FakeDaemon.start(socketPath: socketPath) { _, _ in }
        do {
            _ = try await FakeDaemon.start(socketPath: socketPath) { _, _ in }
            Issue.record("expected the second daemon to refuse the address")
        } catch let error as FakeDaemonError {
            guard case .addressInUse(let reported) = error else {
                Issue.record("wrong FakeDaemonError case")
                return
            }
            #expect(reported == socketPath)
        }
        await first.stop()
    }

    /// The nastier half. Teardown used to unlink whatever was at the path, so
    /// stopping a daemon that never bound would delete a live daemon's socket file
    /// and leave it listening on an address that answers connection-refused.
    @Test("stopping a daemon that never bound leaves the address alone")
    func teardownDoesNotUnlinkSomeoneElsesSocket() async throws {
        let socketPath = Self.path()
        let live = try await FakeDaemon.start(socketPath: socketPath) { _, _ in }

        // A daemon that failed to bind, then torn down in the usual way.
        let loser = FakeDaemon(socketPath: socketPath)
        await loser.stop()

        // The live daemon must still be reachable at its own address.
        #expect(await FakeDaemonAddressTests.answers(at: socketPath),
                "teardown unlinked a socket it did not create")
        await live.stop()
        #expect(await !FakeDaemonAddressTests.answers(at: socketPath))
    }

    private static func answers(at path: String) async -> Bool {
        let probe = FakeDaemon(socketPath: path)
        // start() refuses an address that is already live, which is exactly the
        // question being asked here.
        do {
            let daemon = try await FakeDaemon.start(socketPath: path) { _, _ in }
            await daemon.stop()
            return false
        } catch {
            _ = probe
            return true
        }
    }
}
