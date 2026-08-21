import Msgpack
import TelepathTestKit
import Testing
@testable import Telepath

/// What the handshake puts in `auth`, which is invisible from the client side —
/// every one of these would pass while the server saw the wrong identity.
///
/// The rule is `telepath.py:1613`: a user is sent whenever one is present, with a
/// null password when there is none. This client used to require *both*, so a URL
/// naming a user without a password authenticated as nobody. TLS client
/// certificates take that path, and so does every URL AHA resolves, since AHA
/// supplies a user and never a password.
@Suite struct HandshakeAuthTests {
    private static let session = "0123456789abcdef0123456789abcdef"

    private actor Recorder {
        private(set) var auth: MsgpackValue?
        private(set) var sawHandshake = false
        func record(_ value: MsgpackValue?) {
            sawHandshake = true
            auth = value
        }
    }

    /// Captures the `auth` field of the handshake the client sends.
    ///
    /// The URL is built programmatically rather than parsed: `unix://` takes a
    /// path, not an authority, so credentials cannot be spelled in one — and the
    /// handshake is what is under test here, not the grammar.
    private func authSent(_ configure: (inout TelepathURL) -> Void) async throws -> MsgpackValue? {
        let recorder = Recorder()
        let daemon = try await FakeDaemon.start { message, connection in
            if message.name == "tele:syn" {
                await recorder.record(message.info["auth"])
                try await connection.send(.array([
                    .string("tele:syn"),
                    .map([
                        .string("vers"): .array([.uint(3), .uint(0)]),
                        .string("retn"): .array([.bool(true), .null]),
                        .string("sess"): .string(Self.session),
                        .string("sharinfo"): .map([.string("meths"): .map([:])]),
                        .string("features"): .map([:]),
                    ]),
                ]))
            }
        }
        var url = try TelepathURL(daemon.url)
        configure(&url)
        let proxy = try await Proxy.open(url)
        await proxy.close()
        await daemon.stop()
        #expect(await recorder.sawHandshake)
        return await recorder.auth
    }

    @Test("a user and password are both sent")
    func userAndPassword() async throws {
        let auth = try await authSent { $0.user = "root"; $0.password = "s3cret" }
        #expect(auth?[0]?.stringValue == "root")
        #expect(auth?[1]?["passwd"]?.stringValue == "s3cret")
    }

    /// The regression. AHA resolves to a URL with a user and no password, and the
    /// server answers `AuthDeny: Unable to find cell user (None)` when `auth` is
    /// null — so the identity has to travel even with nothing to authenticate it.
    @Test("a user with no password is still sent, with a null password")
    func userWithoutPassword() async throws {
        let auth = try await authSent { $0.user = "root" }
        #expect(auth?[0]?.stringValue == "root", "the user was dropped from the handshake")
        guard let passwd = auth?[1]?["passwd"] else {
            Issue.record("expected an explicit passwd key")
            return
        }
        #expect(passwd == .null, "expected a null password, got \(passwd)")
    }

    /// No user at all still means no auth: that is an anonymous connection, not an
    /// identity with a missing credential.
    @Test("no user sends no auth")
    func noUser() async throws {
        let auth = try await authSent { _ in }
        #expect(auth == nil || auth == .null)
    }
}
