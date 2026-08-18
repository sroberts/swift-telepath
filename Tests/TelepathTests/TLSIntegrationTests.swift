import Foundation
import Testing
import TelepathTLS
@testable import Telepath

/// TLS against a live ssl:// Cortex.
///
/// Synapse's TLS behaviour is deliberately non-standard — hostname verification is
/// off, a pinned `certhash` disables chain trust entirely, and the certificate's
/// common name is compared instead of its SAN — so only a real server proves it.
///
/// Set TELEPATH_TLS_HOST, TELEPATH_TLS_PORT, TELEPATH_CERT_DIR and
/// TELEPATH_CERT_HASH; see scripts/run-tls-test-cortex.sh.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TELEPATH_CERT_DIR"] != nil))
struct TLSIntegrationTests {
    var environment: [String: String] { ProcessInfo.processInfo.environment }
    var host: String { environment["TELEPATH_TLS_HOST"] ?? "localhost" }
    var port: String { environment["TELEPATH_TLS_PORT"] ?? "27500" }
    var certificateDirectory: String { environment["TELEPATH_CERT_DIR"]! }
    var certHash: String { environment["TELEPATH_CERT_HASH"] ?? "" }
    /// A separate listener, because Synapse sets CERT_REQUIRED on any listener
    /// carrying `?ca=`, so one cannot serve both password and certificate auth.
    var clientCertPort: String? { environment["TELEPATH_TLS_CLIENTCERT_PORT"] }

    private func url(_ query: String, credentials: String = "root:s3cret@") -> String {
        "ssl://\(credentials)\(host):\(port)/?\(query)"
    }

    /// The CA path: verify the chain, then compare the certificate's common name.
    @Test("connects when the CA is trusted and the common name matches")
    func certificateAuthorityPath() async throws {
        let proxy = try await Proxy.open(url("certdir=\(certificateDirectory)"))
        let info = try await proxy.call("getCellInfo")
        #expect(info["cell"]?["type"]?.stringValue == "cortex")
        await proxy.close()
    }

    /// Synapse compares the common name, not the SAN, and does so exactly.
    @Test("rejects a certificate whose common name is not the expected hostname")
    func commonNameMismatch() async throws {
        do {
            let proxy = try await Proxy.open(
                url("certdir=\(certificateDirectory)&hostname=not-the-right-host"))
            await proxy.close()
            Issue.record("expected BadCertHost")
        } catch let error as TLSError {
            guard case .badCertificateHost(let expected, let actual) = error else {
                Issue.record("unexpected TLS error: \(error)")
                return
            }
            #expect(expected == "not-the-right-host")
            #expect(actual == "localhost")
        }
    }

    /// A pinned fingerprint identifies the peer exactly, so chain trust is disabled
    /// and no certdir is needed at all.
    @Test("connects on a matching pinned fingerprint without any CA")
    func pinnedFingerprint() async throws {
        try #require(!certHash.isEmpty, "TELEPATH_CERT_HASH must be set")
        let proxy = try await Proxy.open(url("certhash=\(certHash)"))
        let info = try await proxy.call("getCellInfo")
        #expect(info["cell"]?["type"]?.stringValue == "cortex")
        await proxy.close()
    }

    @Test("rejects a mismatched pinned fingerprint")
    func pinnedFingerprintMismatch() async throws {
        let wrong = String(repeating: "ab", count: 32)
        do {
            let proxy = try await Proxy.open(url("certhash=\(wrong)"))
            await proxy.close()
            Issue.record("expected LinkBadCert")
        } catch let error as TLSError {
            guard case .badCertificate(let expected, let actual) = error else {
                Issue.record("unexpected TLS error: \(error)")
                return
            }
            #expect(expected == wrong)
            #expect(actual != wrong)
        } catch {
            Issue.record("expected TLSError.badCertificate, got \(type(of: error)): \(error)")
        }
    }

    /// Pinning takes precedence over the name check in Synapse (`if certhash ...
    /// elif hostname ...`), so a wrong hostname alongside a right pin still connects.
    @Test("a pinned fingerprint skips the common name check entirely")
    func pinningSkipsCommonNameCheck() async throws {
        try #require(!certHash.isEmpty)
        let proxy = try await Proxy.open(url("certhash=\(certHash)&hostname=not-the-right-host"))
        _ = try await proxy.call("getCellInfo")
        await proxy.close()
    }

    /// A user with no password authenticates from the client certificate, which
    /// Synapse resolves as `{user}@{hostname}`; the handshake's auth stays nil.
    @Test("authenticates with a TLS client certificate and no password")
    func clientCertificateAuthentication() async throws {
        let port = try #require(clientCertPort, "TELEPATH_TLS_CLIENTCERT_PORT must be set")
        let proxy = try await Proxy.open(
            "ssl://root@\(host):\(port)/?certdir=\(certificateDirectory)")
        let whoami = try await proxy.call("getCellUser")
        // Synapse authenticates from the certificate's common name, so the session
        // user is the full `{user}@{hostname}` the certificate was issued for.
        #expect(whoami["name"]?.stringValue == "root@\(host)",
                "the session should be authenticated as the certificate's user")
        await proxy.close()
    }
}
