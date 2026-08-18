import Crypto
import Foundation
import NIOSSL
import Testing
import X509
@testable import TelepathTLS

/// Unit coverage for the TLS layer, with certificates generated in-process.
///
/// Nothing is committed to the repository: test keys in a git history age badly and
/// trip secret scanners, and generating them here keeps the suite runnable anywhere
/// without Synapse or openssl installed.
struct TLSTests {
    /// A throwaway CA and a leaf issued by it.
    struct Fixture {
        let caCertificate: Certificate
        let caKey: Certificate.PrivateKey
        let leafCertificate: Certificate
        let leafKey: Certificate.PrivateKey

        init(leafCommonName: String) throws {
            let caPrivate = P256.Signing.PrivateKey()
            self.caKey = Certificate.PrivateKey(caPrivate)
            let caName = try DistinguishedName { CommonName("telepath test ca") }
            self.caCertificate = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(),
                publicKey: caKey.publicKey,
                notValidBefore: Date().addingTimeInterval(-3600),
                notValidAfter: Date().addingTimeInterval(86_400),
                issuer: caName,
                subject: caName,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                },
                issuerPrivateKey: caKey
            )

            let leafPrivate = P256.Signing.PrivateKey()
            self.leafKey = Certificate.PrivateKey(leafPrivate)
            self.leafCertificate = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(),
                publicKey: leafKey.publicKey,
                notValidBefore: Date().addingTimeInterval(-3600),
                notValidAfter: Date().addingTimeInterval(86_400),
                issuer: caName,
                subject: try DistinguishedName { CommonName(leafCommonName) },
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                },
                issuerPrivateKey: caKey
            )
        }

        /// Writes the fixture in Synapse's certificate directory layout.
        func writeSynapseLayout(user: String) throws -> URL {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("telepath-certs-\(UUID().uuidString)")
            for sub in ["cas", "hosts", "users"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            try caCertificate.serializeAsPEM().pemString
                .write(to: root.appendingPathComponent("cas/telepathtestca.crt"),
                       atomically: true, encoding: .utf8)
            try leafCertificate.serializeAsPEM().pemString
                .write(to: root.appendingPathComponent("users/\(user).crt"),
                       atomically: true, encoding: .utf8)
            try leafKey.serializeAsPEM().pemString
                .write(to: root.appendingPathComponent("users/\(user).key"),
                       atomically: true, encoding: .utf8)
            return root
        }

        var leafAsNIOSSL: NIOSSLCertificate {
            get throws {
                try NIOSSLCertificate(bytes: Array(leafCertificate.serializeAsPEM().pemString.utf8),
                                      format: .pem)
            }
        }
    }

    // MARK: - Certificate directory

    @Test("the Synapse certificate directory layout is read")
    func certificateDirectoryLayout() throws {
        let fixture = try Fixture(leafCommonName: "root@localhost")
        let root = try fixture.writeSynapseLayout(user: "root@localhost")
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = CertificateDirectory(root: root)
        #expect(try directory.certificateAuthorities().count == 1)

        let identity = try directory.clientIdentity(named: "root@localhost")
        #expect(identity.chain.count == 1)
    }

    /// An empty CA directory almost always means the wrong path, so it is an error
    /// rather than a silently trust-nothing configuration.
    @Test("a directory with no CAs is an error, not an empty trust store")
    func missingCertificateAuthorities() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telepath-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: TLSError.self) { try CertificateDirectory(root: root).certificateAuthorities() }
    }

    @Test("a missing client certificate or key names what is absent")
    func missingClientIdentity() throws {
        let fixture = try Fixture(leafCommonName: "root@localhost")
        let root = try fixture.writeSynapseLayout(user: "root@localhost")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = CertificateDirectory(root: root)

        #expect(throws: TLSError.self) { try directory.clientIdentity(named: "nobody@nowhere") }

        try FileManager.default.removeItem(at: root.appendingPathComponent("users/root@localhost.key"))
        #expect(throws: TLSError.self) { try directory.clientIdentity(named: "root@localhost") }
    }

    /// Synapse resolves a client certificate as `{user}@{hostname}`.
    @Test("the client certificate name follows Synapse's convention")
    func clientCertificateNaming() {
        #expect(CertificateDirectory.clientCertificateName(user: "visi", hostname: "cortex.vertex.link")
                == "visi@cortex.vertex.link")
    }

    // MARK: - Fingerprints

    @Test("the fingerprint is the SHA-256 of the DER encoding")
    func fingerprintMatchesDigest() throws {
        let fixture = try Fixture(leafCommonName: "localhost")
        let certificate = try fixture.leafAsNIOSSL

        let expected = SHA256.hash(data: try certificate.toDERBytes())
            .map { String(format: "%02x", $0) }.joined()
        #expect(try TelepathTLS.fingerprint(of: certificate) == expected)
        #expect(expected.count == 64)
    }

    @Test("fingerprints are accepted in the forms people paste")
    func fingerprintNormalisation() throws {
        let digest = String(repeating: "ab", count: 32)
        #expect(try TelepathTLS.normalizeFingerprint(digest.uppercased()) == digest)

        let colonised = stride(from: 0, to: 64, by: 2)
            .map { String(Array(digest)[$0..<$0 + 2]) }.joined(separator: ":")
        #expect(try TelepathTLS.normalizeFingerprint(colonised) == digest)
    }

    @Test("a malformed fingerprint is rejected rather than silently disabling pinning")
    func fingerprintRejection() {
        #expect(throws: TLSError.self) { try TelepathTLS.normalizeFingerprint("not a digest") }
        #expect(throws: TLSError.self) { try TelepathTLS.normalizeFingerprint("abc") }
        #expect(throws: TLSError.self) { try TelepathTLS.normalizeFingerprint(String(repeating: "z", count: 64)) }
    }

    // MARK: - Common name

    /// Synapse compares the subject common name, not the subject alternative name.
    @Test("the subject common name is extracted")
    func commonNameExtraction() throws {
        let fixture = try Fixture(leafCommonName: "cortex.vertex.link")
        #expect(try TelepathTLS.commonName(of: try fixture.leafAsNIOSSL) == "cortex.vertex.link")
    }

    @Test("contexts build for both policies")
    func contextConstruction() throws {
        let fixture = try Fixture(leafCommonName: "localhost")
        let root = try fixture.writeSynapseLayout(user: "root@localhost")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = CertificateDirectory(root: root)

        _ = try TelepathTLS.makeContext(
            policy: .pinnedFingerprint(String(repeating: "ab", count: 32)),
            certificateDirectory: nil, clientCertificateName: nil)

        _ = try TelepathTLS.makeContext(
            policy: .certificateAuthority(expectedHostname: "localhost"),
            certificateDirectory: directory, clientCertificateName: "root@localhost")
    }
}
