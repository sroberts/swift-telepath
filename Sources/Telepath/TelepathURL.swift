import Foundation

/// A parsed Telepath URL.
///
/// The grammar is Synapse's, not RFC 3986's. Two deviations bite:
/// `unix://` and `cell://` carry the share name after a **colon** inside the path
/// (`unix:///var/run/sock:cortex`), and the share name itself may contain slashes
/// — the daemon splits on the first one, resolving the leading segment as the
/// shared object and passing the remainder to `getTeleApi` as a path.
public struct TelepathURL: Sendable, Equatable {
    public enum Scheme: String, Sendable {
        case tcp, ssl, unix, cell
    }

    /// Synapse's default Telepath port.
    public static let defaultPort = 27492
    /// The daemon's name for "the default shared object".
    public static let defaultShare = "*"

    public var scheme: Scheme = .tcp
    public var host: String?
    public var port: Int = TelepathURL.defaultPort
    public var path: String?
    public var user: String?
    public var password: String?
    public var share: String = TelepathURL.defaultShare
    public var certName: String?
    public var certHash: String?
    public var hostnameOverride: String?
    public var certDirectory: String?
    /// Query parameters that are not part of the known set. Surfaced rather than
    /// dropped so a typo in `certhash=` cannot silently disable pinning.
    public var unknownParameters: [String: String] = [:]

    /// The name to verify a server certificate against: the explicit `hostname`
    /// parameter when present, otherwise the connected host.
    public var expectedHostname: String? { hostnameOverride ?? host }

    public init(_ string: String) throws {
        guard let separator = string.range(of: "://") else {
            throw TelepathError.invalidURL(string, reason: "missing scheme separator '://'")
        }
        let rawScheme = String(string[string.startIndex..<separator.lowerBound]).lowercased()
        var remainder = String(string[separator.upperBound...])

        if rawScheme.contains("+consul") {
            throw TelepathError.invalidURL(string, reason: "consul resolution was removed upstream")
        }
        if rawScheme == "aha" {
            throw TelepathError.unsupportedScheme(rawScheme,
                reason: "aha:// resolution requires an AHA client and is not implemented")
        }
        guard let scheme = Scheme(rawValue: rawScheme) else {
            throw TelepathError.unsupportedScheme(rawScheme, reason: "unknown Telepath scheme")
        }
        self.scheme = scheme

        // Split the query off first so nothing below has to cope with '?'.
        var query: [String: String] = [:]
        if let mark = remainder.firstIndex(of: "?") {
            query = Self.parseQuery(String(remainder[remainder.index(after: mark)...]))
            remainder = String(remainder[remainder.startIndex..<mark])
        }

        switch scheme {
        case .tcp, .ssl:
            try parseNetworkAuthority(remainder, original: string)
        case .unix, .cell:
            // Path and share are colon-separated; the share is optional.
            let (rawPath, shareName) = Self.splitTrailingShare(remainder)
            guard !rawPath.isEmpty else {
                throw TelepathError.invalidURL(string, reason: "\(rawScheme):// requires a filesystem path")
            }
            self.host = nil
            self.port = 0
            self.share = shareName ?? Self.defaultShare
            // cell:// names a cell directory; the socket lives inside it.
            self.path = scheme == .cell ? (rawPath as NSString).appendingPathComponent("sock") : rawPath
        }

        var params = query
        self.certName = params.removeValue(forKey: "certname")
        self.certHash = params.removeValue(forKey: "certhash")
        self.hostnameOverride = params.removeValue(forKey: "hostname")
        self.certDirectory = params.removeValue(forKey: "certdir")
        if let name = params.removeValue(forKey: "name") {
            self.share = name
        }
        self.unknownParameters = params
    }

    private mutating func parseNetworkAuthority(_ remainder: String, original: String) throws {
        var authority = remainder
        var pathPart = ""
        if let slash = authority.firstIndex(of: "/") {
            pathPart = String(authority[authority.index(after: slash)...])
            authority = String(authority[authority.startIndex..<slash])
        }

        // Credentials, if any, precede the last '@' — passwords may contain '@'.
        if let at = authority.lastIndex(of: "@") {
            let credentials = String(authority[authority.startIndex..<at])
            authority = String(authority[authority.index(after: at)...])
            if let colon = credentials.firstIndex(of: ":") {
                self.user = Self.percentDecode(String(credentials[credentials.startIndex..<colon]))
                self.password = Self.percentDecode(String(credentials[credentials.index(after: colon)...]))
            } else {
                self.user = Self.percentDecode(credentials)
            }
        }

        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            // IPv6 literal.
            self.host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            self.port = rest.hasPrefix(":") ? (Int(rest.dropFirst()) ?? Self.defaultPort) : Self.defaultPort
        } else if let colon = authority.lastIndex(of: ":") {
            self.host = String(authority[authority.startIndex..<colon])
            guard let parsed = Int(authority[authority.index(after: colon)...]), (1...65535).contains(parsed) else {
                throw TelepathError.invalidURL(original, reason: "invalid port")
            }
            self.port = parsed
        } else {
            self.host = authority
            self.port = Self.defaultPort
        }

        guard let host = self.host, !host.isEmpty else {
            throw TelepathError.invalidURL(original, reason: "missing host")
        }
        // An empty path means the default share, spelled '*' on the wire.
        self.share = pathPart.isEmpty ? Self.defaultShare : pathPart
    }

    /// Splits `path:share`, tolerating absolute paths that contain no colon.
    /// Only a colon in the final path component counts, so `/a:b/sock` keeps its path.
    private static func splitTrailingShare(_ raw: String) -> (String, String?) {
        guard let lastSlash = raw.lastIndex(of: "/") else {
            if let colon = raw.firstIndex(of: ":") {
                return (String(raw[raw.startIndex..<colon]), String(raw[raw.index(after: colon)...]))
            }
            return (raw, nil)
        }
        let component = raw[raw.index(after: lastSlash)...]
        guard let colon = component.firstIndex(of: ":") else { return (raw, nil) }
        return (String(raw[raw.startIndex..<colon]), String(raw[raw.index(after: colon)...]))
    }

    private static func parseQuery(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else {
                out[String(pair).lowercased()] = ""
                continue
            }
            let key = String(pair[pair.startIndex..<equals]).lowercased()
            out[key] = percentDecode(String(pair[pair.index(after: equals)...]))
        }
        return out
    }

    private static func percentDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }
}
