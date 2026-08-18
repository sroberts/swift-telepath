import Foundation
import Testing
import TelepathTLS
@testable import Telepath

/// Failure paths for ssl:// that need no server.
///
/// Every TLS test that talks to a live listener exercises a connection that
/// succeeds at the transport layer. These cover the paths where it does not, which
/// is where a promise gets abandoned — and NIO traps on a leaked promise, so the
/// symptom is the process dying rather than an error being thrown.
struct TLSFailureTests {
    private let pin = String(repeating: "ab", count: 32)

    /// Regression: a channel that never activates never fires channelInactive, so
    /// nothing settled the handshake promise and a refused connection crashed the
    /// process with "Fatal error: leaking promise".
    @Test("a refused ssl:// connection throws instead of crashing")
    func refusedConnection() async throws {
        await #expect(throws: (any Error).self) {
            let proxy = try await Proxy.open("ssl://127.0.0.1:1/?certhash=\(pin)")
            await proxy.close()
        }
    }

    @Test("a refused tcp:// connection throws")
    func refusedPlaintextConnection() async throws {
        await #expect(throws: (any Error).self) {
            let proxy = try await Proxy.open("tcp://127.0.0.1:1/")
            await proxy.close()
        }
    }

    /// The fingerprint is validated inside the channel initializer, so this throws
    /// while the handshake promise is already alive — the other way to leak it.
    @Test("a malformed certhash is reported and does not leak the handshake promise")
    func malformedFingerprint() async throws {
        do {
            let proxy = try await Proxy.open("ssl://127.0.0.1:1/?certhash=not-a-digest")
            await proxy.close()
            Issue.record("expected a malformed fingerprint to be rejected")
        } catch let error as TLSError {
            #expect(error == .malformedFingerprint("not-a-digest"))
        } catch {
            // Rejected during connect setup is also acceptable; not crashing is the point.
            #expect(Bool(true))
        }
    }

    /// A missing certificate directory must fail rather than silently trusting
    /// nothing, and must not hang.
    @Test("a certificate directory with no CAs is reported")
    func missingCertificateAuthorities() async throws {
        let missing = NSTemporaryDirectory() + "telepath-absent-\(UUID().uuidString)"
        await #expect(throws: (any Error).self) {
            let proxy = try await Proxy.open("ssl://127.0.0.1:1/?certdir=\(missing)")
            await proxy.close()
        }
    }

    /// Connecting to a plaintext port with ssl:// must fail promptly. Before the
    /// handshake gained a deadline, a peer that accepted and never spoke TLS left
    /// the caller suspended forever: connectTimeout stops applying once the TCP
    /// connection is up.
    @Test("ssl:// against a plaintext port fails rather than hanging",
          .timeLimit(.minutes(1)))
    func plaintextPeer() async throws {
        guard let plain = ProcessInfo.processInfo.environment["TELEPATH_TEST_URL"],
              let url = try? TelepathURL(plain), url.scheme == .tcp, let host = url.host else {
            return   // needs the plaintext Cortex from run-test-cortex.sh
        }
        await #expect(throws: (any Error).self) {
            let proxy = try await Proxy.open("ssl://\(host):\(url.port)/?certhash=\(pin)")
            await proxy.close()
        }
    }
}
