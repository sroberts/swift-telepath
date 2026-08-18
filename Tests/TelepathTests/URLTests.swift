import Testing
@testable import Telepath

/// Synapse's URL grammar is not RFC 3986. These cases are the ones where a
/// well-behaved general-purpose URL parser gets the wrong answer.
struct TelepathURLTests {
    @Test("tcp defaults to port 27492 and the '*' share")
    func tcpDefaults() throws {
        let url = try TelepathURL("tcp://cortex.example.com")
        #expect(url.scheme == .tcp)
        #expect(url.host == "cortex.example.com")
        #expect(url.port == 27492)
        #expect(url.share == "*")
    }

    @Test("credentials and an explicit port parse")
    func credentials() throws {
        let url = try TelepathURL("tcp://root:secret@10.0.0.5:1234/cortex")
        #expect(url.user == "root")
        #expect(url.password == "secret")
        #expect(url.host == "10.0.0.5")
        #expect(url.port == 1234)
        #expect(url.share == "cortex")
    }

    @Test("a password containing '@' splits on the last '@', not the first")
    func passwordWithAtSign() throws {
        let url = try TelepathURL("tcp://user:p@ss@host:27492")
        #expect(url.user == "user")
        #expect(url.password == "p@ss")
        #expect(url.host == "host")
    }

    @Test("percent-encoded credentials are decoded")
    func percentEncoding() throws {
        let url = try TelepathURL("tcp://user:p%40ss%2F1@host")
        #expect(url.password == "p@ss/1")
    }

    /// The daemon splits the share on the first '/', resolving the leading segment
    /// as the object and passing the rest to getTeleApi. The client sends it whole.
    @Test("a multi-segment share name is preserved verbatim")
    func nestedShare() throws {
        #expect(try TelepathURL("tcp://host:27492/cortex/foo/bar").share == "cortex/foo/bar")
    }

    @Test("unix takes the share after a colon, not a slash")
    func unixShare() throws {
        let url = try TelepathURL("unix:///var/run/syn.sock:cortex")
        #expect(url.scheme == .unix)
        #expect(url.path == "/var/run/syn.sock")
        #expect(url.share == "cortex")
    }

    @Test("unix without a share defaults to '*'")
    func unixDefaultShare() throws {
        let url = try TelepathURL("unix:///var/run/syn.sock")
        #expect(url.path == "/var/run/syn.sock")
        #expect(url.share == "*")
    }

    /// cell:// names a directory; the socket lives inside it.
    @Test("cell appends 'sock' to the cell directory")
    func cellPath() throws {
        let url = try TelepathURL("cell:///srv/cortex00:cortex")
        #expect(url.path == "/srv/cortex00/sock")
        #expect(url.share == "cortex")
    }

    @Test("TLS parameters parse and 'name' overrides the path share")
    func tlsParameters() throws {
        let url = try TelepathURL("ssl://user@host:27492/svc?certname=me&certhash=abc123&hostname=real.host&name=other")
        #expect(url.certName == "me")
        #expect(url.certHash == "abc123")
        #expect(url.hostnameOverride == "real.host")
        #expect(url.expectedHostname == "real.host")
        #expect(url.share == "other")
    }

    /// A typo'd parameter must be visible: silently dropping 'certhsh=' would
    /// disable pinning without telling anyone.
    @Test("unknown query parameters are surfaced, not dropped")
    func unknownParameters() throws {
        let url = try TelepathURL("ssl://host?certhsh=oops")
        #expect(url.certHash == nil)
        #expect(url.unknownParameters["certhsh"] == "oops")
    }

    @Test("IPv6 literals parse")
    func ipv6() throws {
        let url = try TelepathURL("tcp://[::1]:1234/cortex")
        #expect(url.host == "::1")
        #expect(url.port == 1234)
    }

    @Test("out-of-scope and removed schemes fail with a clear reason")
    func rejectedSchemes() {
        #expect(throws: TelepathError.self) { try TelepathURL("aha://network/service") }
        #expect(throws: TelepathError.self) { try TelepathURL("tcp+consul://host/svc") }
        #expect(throws: TelepathError.self) { try TelepathURL("http://host/svc") }
        #expect(throws: TelepathError.self) { try TelepathURL("nonsense") }
        #expect(throws: TelepathError.self) { try TelepathURL("tcp://host:99999") }
    }
}
