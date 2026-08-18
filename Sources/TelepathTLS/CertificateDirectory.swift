import Foundation
import NIOSSL

/// Reads a Synapse certificate directory.
///
/// The layout is Synapse's own and undocumented outside its source:
///
/// ```
/// certs/
///   cas/<name>.crt     <name>.key
///   hosts/<name>.crt   <name>.key
///   users/<name>.crt   <name>.key
/// ```
///
/// Supporting it directly means existing deployments work without re-provisioning
/// certificates into some other shape.
public struct CertificateDirectory: Sendable {
    public let root: URL

    /// Synapse's default location.
    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["SYN_CERT_DIR"]
            ?? ProcessInfo.processInfo.environment["SYN_CERTDIR"] {
            return URL(fileURLWithPath: expandingTilde(override))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".syn")
            .appendingPathComponent("certs")
    }

    public init(root: URL) {
        self.root = root
    }

    public init?(path: String?) {
        guard let path else { return nil }
        self.root = URL(fileURLWithPath: CertificateDirectory.expandingTilde(path))
    }

    /// Synapse routes certdir paths through `s_common.genpath`, which expands `~`,
    /// so `?certdir=~/.syn/certs` works against the Python client and must here too.
    static func expandingTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public var caDirectory: URL { root.appendingPathComponent("cas") }
    public var hostDirectory: URL { root.appendingPathComponent("hosts") }
    public var userDirectory: URL { root.appendingPathComponent("users") }

    /// Every CA certificate in the directory, used as trust roots.
    ///
    /// Synapse deployments routinely run a private CA, so an empty result almost
    /// always means the wrong directory rather than a deployment with no CAs.
    public func certificateAuthorities() throws -> [NIOSSLCertificate] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: caDirectory, includingPropertiesForKeys: nil)) ?? []

        var certificates: [NIOSSLCertificate] = []
        for url in contents.sorted(by: { $0.path < $1.path }) where url.pathExtension == "crt" {
            certificates.append(contentsOf: try NIOSSLCertificate.fromPEMFile(url.path))
        }
        guard !certificates.isEmpty else {
            throw TLSError.noCertificateAuthorities(directory: caDirectory.path)
        }
        return certificates
    }

    /// A client identity for TLS client-certificate authentication.
    ///
    /// Synapse names these `{user}@{hostname}`; the daemon then authenticates the
    /// session from the certificate and the handshake's `auth` field stays nil.
    public func clientIdentity(named name: String) throws -> ClientIdentity {
        let certificate = userDirectory.appendingPathComponent("\(name).crt")
        let key = userDirectory.appendingPathComponent("\(name).key")

        guard FileManager.default.fileExists(atPath: certificate.path) else {
            throw TLSError.missingClientCertificate(name: name, path: certificate.path)
        }
        guard FileManager.default.fileExists(atPath: key.path) else {
            throw TLSError.missingClientKey(name: name, path: key.path)
        }
        return ClientIdentity(
            chain: try NIOSSLCertificate.fromPEMFile(certificate.path),
            privateKey: try NIOSSLPrivateKey(file: key.path, format: .pem)
        )
    }

    /// The name Synapse resolves a client certificate under for `user` on `host`.
    public static func clientCertificateName(user: String, hostname: String) -> String {
        "\(user)@\(hostname)"
    }

    public struct ClientIdentity: Sendable {
        public let chain: [NIOSSLCertificate]
        public let privateKey: NIOSSLPrivateKey
    }
}

public enum TLSError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The pinned SHA-256 fingerprint did not match the peer's certificate.
    /// Synapse raises `LinkBadCert` here.
    case badCertificate(expected: String, actual: String)
    /// The certificate's subject common name did not match the expected hostname.
    /// Synapse raises `BadCertHost`.
    case badCertificateHost(expected: String, actual: String?)
    case noCertificateAuthorities(directory: String)
    case missingClientCertificate(name: String, path: String)
    case missingClientKey(name: String, path: String)
    case malformedCertificate(String)
    case malformedFingerprint(String)
    case handshakeIncomplete
    /// The peer closed before the handshake finished, most often because it
    /// rejected the client certificate.
    case peerClosedDuringHandshake
    case handshakeTimedOut

    public var description: String {
        switch self {
        case .badCertificate(let expected, let actual):
            return "LinkBadCert: certificate fingerprint \(actual) does not match pinned \(expected)"
        case .badCertificateHost(let expected, let actual):
            return "BadCertHost: certificate common name \(actual ?? "<none>") does not match \(expected)"
        case .noCertificateAuthorities(let directory):
            return "no CA certificates found in \(directory)"
        case .missingClientCertificate(let name, let path):
            return "no client certificate '\(name)' at \(path)"
        case .missingClientKey(let name, let path):
            return "no private key for client certificate '\(name)' at \(path)"
        case .malformedCertificate(let detail):
            return "malformed certificate: \(detail)"
        case .malformedFingerprint(let value):
            return "certhash is not a SHA-256 hex digest: \(value)"
        case .handshakeIncomplete:
            return "the TLS handshake completed without a peer certificate"
        case .peerClosedDuringHandshake:
            return "the peer closed the connection during the TLS handshake, "
                + "which usually means it rejected the client certificate"
        case .handshakeTimedOut:
            return "the TLS handshake did not complete before the timeout"
        }
    }
}
