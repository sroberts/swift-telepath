import Crypto
import Foundation
import NIOCore
import NIOSSL
import NIOTLS
import X509

/// How a server certificate is to be trusted.
///
/// Synapse deliberately does not use standard hostname verification, because its
/// services routinely run on dynamic IPs. Reproducing that exactly is not optional:
/// a conventional TLS client fails to connect to real deployments.
public enum TLSPolicy: Sendable, Equatable {
    /// A pinned SHA-256 fingerprint of the peer's DER certificate. Chain trust is
    /// disabled entirely, matching Synapse's `CERT_NONE` plus a manual comparison.
    case pinnedFingerprint(String)

    /// Verify against the CA chain, then compare the certificate's subject
    /// **common name** to this hostname. Note CN, not SAN — Synapse checks CN.
    case certificateAuthority(expectedHostname: String)
}

/// Carries a verification failure out of the TLS callback.
///
/// BoringSSL collapses whatever the callback throws into a generic
/// `CERTIFICATE_VERIFY_FAILED`, which tells a caller nothing about *why* the peer
/// was rejected. The real error is stashed here so the handshake gate can report
/// it instead. Confined to the channel's event loop.
public final class TLSVerificationFailure: @unchecked Sendable {
    public private(set) var error: (any Error)?

    public init() {}

    public func record(_ error: any Error) {
        if self.error == nil { self.error = error }
    }
}

public struct TelepathTLS {
    /// Builds the TLS context and the handler that enforces ``TLSPolicy``.
    ///
    /// `certificateVerification` is never `.fullVerification`: hostname checking is
    /// off in both modes because Synapse turns off `check_hostname`.
    public static func makeContext(
        policy: TLSPolicy,
        certificateDirectory: CertificateDirectory?,
        clientCertificateName: String?
    ) throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        // Synapse closes without waiting for close_notify, so the default five
        // second shutdown wait is spent on every link teardown for nothing.
        configuration.shutdownTimeout = .milliseconds(200)

        switch policy {
        case .pinnedFingerprint:
            // Verification must stay enabled or BoringSSL never invokes the custom
            // callback and every certificate is accepted — pinning silently off.
            // The callback overrides BoringSSL's logic entirely, so trust roots are
            // irrelevant here and an untrusted certificate still passes on a
            // matching pin, which is what Synapse's CERT_NONE plus manual
            // comparison does.
            configuration.certificateVerification = .noHostnameVerification

        case .certificateAuthority:
            // BoringSSL verifies the chain; hostname checking stays off and the
            // common name is compared after the handshake instead.
            configuration.certificateVerification = .noHostnameVerification
            if let certificateDirectory {
                configuration.trustRoots = .certificates(try certificateDirectory.certificateAuthorities())
            }
        }

        // A user with no password authenticates by client certificate; the daemon
        // reads the identity from the certificate and `auth` stays nil.
        if let clientCertificateName, let certificateDirectory {
            let identity = try certificateDirectory.clientIdentity(named: clientCertificateName)
            configuration.certificateChain = identity.chain.map { .certificate($0) }
            configuration.privateKey = .privateKey(identity.privateKey)
        }

        return try NIOSSLContext(configuration: configuration)
    }

    /// The client handler for this policy, wired with pin checking where required.
    public static func makeHandler(
        context: NIOSSLContext,
        policy: TLSPolicy,
        serverHostname: String?,
        failure: TLSVerificationFailure
    ) throws -> NIOSSLClientHandler {
        switch policy {
        case .pinnedFingerprint(let expected):
            let normalized = try normalizeFingerprint(expected)
            return try NIOSSLClientHandler(
                context: context,
                // SNI only. No hostname verification is implied: the callback below
                // is the only thing that can accept the peer.
                serverHostname: sniHostname(serverHostname),
                customVerificationCallback: { certificates, promise in
                    do {
                        guard let leaf = certificates.first else {
                            throw TLSError.handshakeIncomplete
                        }
                        let actual = try fingerprint(of: leaf)
                        guard actual == normalized else {
                            throw TLSError.badCertificate(expected: normalized, actual: actual)
                        }
                        promise.succeed(.certificateVerified)
                    } catch {
                        // Kept for the gate handler; BoringSSL would otherwise
                        // reduce this to CERTIFICATE_VERIFY_FAILED.
                        failure.record(error)
                        promise.fail(error)
                    }
                }
            )

        case .certificateAuthority:
            // The context is configured .noHostnameVerification, so this supplies
            // SNI without NIOSSL doing any name checking of its own; the
            // common-name comparison happens in TLSHandshakeHandler.
            return try NIOSSLClientHandler(context: context,
                                           serverHostname: sniHostname(serverHostname))
        }
    }

    /// The name to send as SNI, which Synapse's client supplies as asyncio's
    /// `server_hostname`. A server that selects its certificate by SNI — a
    /// TLS-terminating proxy, a multi-tenant listener — hands back the wrong
    /// certificate without it.
    ///
    /// IP literals are excluded because SNI forbids them and NIOSSL throws
    /// `cannotUseIPAddressInSNI`.
    static func sniHostname(_ hostname: String?) -> String? {
        guard let hostname, !hostname.isEmpty else { return nil }
        if (try? SocketAddress(ipAddress: hostname, port: 0)) != nil { return nil }
        return hostname
    }

    /// The SHA-256 fingerprint of a certificate's DER encoding, lowercase hex.
    public static func fingerprint(of certificate: NIOSSLCertificate) throws -> String {
        let der = try certificate.toDERBytes()
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Accepts the forms people paste: mixed case, and colon- or space-separated.
    public static func normalizeFingerprint(_ value: String) throws -> String {
        let cleaned = value.lowercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard cleaned.count == 64, cleaned.allSatisfy(\.isHexDigit) else {
            throw TLSError.malformedFingerprint(value)
        }
        return cleaned
    }

    /// The subject common name, which is what Synapse compares against the hostname.
    public static func commonName(of certificate: NIOSSLCertificate) throws -> String? {
        let der = try certificate.toDERBytes()
        let parsed: Certificate
        do {
            parsed = try Certificate(derEncoded: der)
        } catch {
            throw TLSError.malformedCertificate("\(error)")
        }
        for relativeName in parsed.subject {
            for attribute in relativeName where attribute.type == .RDNAttributeType.commonName {
                return attribute.value.description
            }
        }
        return nil
    }
}

/// Gates the connection on a completed, verified handshake.
///
/// Two jobs, both about surfacing the right error at the right time:
///
/// 1. When a common name is expected, compare it once BoringSSL has verified the
///    chain. The peer is already known to be issued by a trusted CA at that point —
///    only its name is unchecked — and the connection is closed on mismatch before
///    any credentials are sent.
/// 2. Resolve a promise so the connecting caller waits for the handshake and sees
///    the actual failure. Without it a rejected certificate surfaces as
///    "I/O on closed channel" from the first write, which tells nobody anything.
public final class TLSHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    public typealias InboundIn = NIOAny
    public typealias InboundOut = NIOAny

    private let expectedHostname: String?
    private let promise: EventLoopPromise<Void>
    private let failure: TLSVerificationFailure
    private let timeout: TimeAmount
    private var deadline: Scheduled<Void>?
    private var settled = false

    /// - Parameters:
    ///   - expectedHostname: nil when a pinned fingerprint already identifies the peer.
    ///   - promise: fulfilled when the handshake completes or fails, so the
    ///     connecting caller sees the real error rather than a later write failure.
    ///   - failure: carries the verification callback's reason out of BoringSSL,
    ///     which would otherwise collapse it to a generic verification failure.
    ///   - timeout: connect timeouts stop applying once the TCP connection is up,
    ///     so a peer that accepts and then never speaks TLS would hang the caller
    ///     forever without this.
    public init(expectedHostname: String?, promise: EventLoopPromise<Void>,
                failure: TLSVerificationFailure, timeout: TimeAmount) {
        self.expectedHostname = expectedHostname
        self.promise = promise
        self.failure = failure
        self.timeout = timeout
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        // Capture the channel, not the context: ChannelHandlerContext is not
        // Sendable and must not escape into a scheduled closure, even one that
        // runs on the same event loop.
        let channel = context.channel
        deadline = context.eventLoop.scheduleTask(in: timeout) { [weak self] in
            self?.settle(.failure(TLSError.handshakeTimedOut))
            channel.close(promise: nil)
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard case .handshakeCompleted = event as? TLSUserEvent else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        do {
            try verify(context: context)
            settle(.success(()))
        } catch {
            settle(.failure(error))
            context.fireErrorCaught(error)
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // Prefer the reason recorded by the verification callback: a rejected pin
        // arrives here as a generic BoringSSL handshake failure otherwise.
        settle(.failure(failure.error ?? error))
        context.fireErrorCaught(error)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        // Distinct from handshakeIncomplete: the common cause is a server rejecting
        // the client certificate and dropping the connection.
        settle(.failure(failure.error ?? TLSError.peerClosedDuringHandshake))
        context.fireChannelInactive()
    }

    private func settle(_ result: Result<Void, any Error>) {
        guard !settled else { return }
        settled = true
        deadline?.cancel()
        deadline = nil
        promise.completeWith(result)
    }

    private func verify(context: ChannelHandlerContext) throws {
        guard let expectedHostname else { return }   // pinned: name is not consulted

        // peerCertificate is documented as not thread safe; this runs on the event
        // loop, which is where the handler's own callbacks run.
        guard let handler = try? context.pipeline.syncOperations.handler(type: NIOSSLClientHandler.self),
              let certificate = handler.peerCertificate else {
            throw TLSError.handshakeIncomplete
        }
        let name = try TelepathTLS.commonName(of: certificate)

        // Exact string equality, matching synapse/lib/link.py:
        //
        //     if self.hostname != self.getTlsPeerCn():
        //         raise s_exc.BadCertHost(...)
        //
        // Deliberately no wildcard handling and no case folding. Being more
        // permissive than the reference would mean certificates that work here and
        // fail against a Python client, which is a worse failure than a strict match.
        guard let name, name == expectedHostname else {
            throw TLSError.badCertificateHost(expected: expectedHostname, actual: name)
        }
    }
}
