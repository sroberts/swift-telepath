import Msgpack

/// An error raised by the remote service.
///
/// Synapse reconstructs the exception class by name from `synapse.exc`. Swift
/// cannot and should not mirror hundreds of classes, so the name is kept as data
/// and the full decoded `info` map is preserved. Decoding never fails because a
/// name is unrecognised.
public struct TelepathRemoteError: Error, Sendable, Equatable {
    public let name: String
    public let mesg: String?
    public let info: [String: MsgpackValue]

    public init(name: String, mesg: String?, info: [String: MsgpackValue]) {
        self.name = name
        self.mesg = mesg
        self.info = info
    }

    public var kind: TelepathErrorName { TelepathErrorName(name) }

    /// Source location of the raising frame, when the server had a traceback.
    public var file: String? { info["efile"]?.stringValue }
    public var line: Int? { info["eline"].flatMap { $0.intValue.map(Int.init) } }
}

extension TelepathRemoteError {
    /// Builds an error from the `(excName, info)` arm of a retn tuple.
    ///
    /// Public because Storm carries the same shape in its `err` messages, and
    /// deliberately non-failing: an unrecognised name or malformed info map still
    /// produces a usable error, since throwing here would mask the server's fault.
    public init(errorTuple value: MsgpackValue) {
        guard let items = value.arrayValue, let name = items.first?.stringValue else {
            self.init(name: "BadMesgFormat", mesg: "malformed error tuple: \(value)", info: [:])
            return
        }
        var info: [String: MsgpackValue] = [:]
        if items.count > 1, case .map(let map) = items[1] {
            for (key, entry) in map {
                if let key = key.stringValue { info[key] = entry }
            }
        }
        self.init(name: name, mesg: info["mesg"]?.stringValue, info: info)
    }
}

extension TelepathRemoteError: CustomStringConvertible {
    public var description: String {
        mesg.map { "\(name): \($0)" } ?? name
    }
}

/// The Synapse exception names clients actually branch on. `.other` exists because
/// the set is open — a new name must never break decoding.
public enum TelepathErrorName: Sendable, Equatable {
    case authDeny
    case noSuchName
    case noSuchMeth
    case noSuchObj
    case badMesgVers
    case badMesgFormat
    case badSyntax
    case badTypeValu
    case isFini
    case linkShutDown
    case linkBadCert
    case badCertHost
    case schemaViolation
    case timeOut
    case other(String)

    public init(_ name: String) {
        switch name {
        case "AuthDeny": self = .authDeny
        case "NoSuchName": self = .noSuchName
        case "NoSuchMeth": self = .noSuchMeth
        case "NoSuchObj": self = .noSuchObj
        case "BadMesgVers": self = .badMesgVers
        case "BadMesgFormat": self = .badMesgFormat
        case "BadSyntax": self = .badSyntax
        case "BadTypeValu": self = .badTypeValu
        case "IsFini": self = .isFini
        case "LinkShutDown": self = .linkShutDown
        case "LinkBadCert": self = .linkBadCert
        case "BadCertHost": self = .badCertHost
        case "SchemaViolation": self = .schemaViolation
        case "TimeOut": self = .timeOut
        default: self = .other(name)
        }
    }

    public var rawName: String {
        switch self {
        case .authDeny: return "AuthDeny"
        case .noSuchName: return "NoSuchName"
        case .noSuchMeth: return "NoSuchMeth"
        case .noSuchObj: return "NoSuchObj"
        case .badMesgVers: return "BadMesgVers"
        case .badMesgFormat: return "BadMesgFormat"
        case .badSyntax: return "BadSyntax"
        case .badTypeValu: return "BadTypeValu"
        case .isFini: return "IsFini"
        case .linkShutDown: return "LinkShutDown"
        case .linkBadCert: return "LinkBadCert"
        case .badCertHost: return "BadCertHost"
        case .schemaViolation: return "SchemaViolation"
        case .timeOut: return "TimeOut"
        case .other(let name): return name
        }
    }
}

/// Client-side failures: malformed URLs, protocol violations, and transport loss.
/// Distinct from ``TelepathRemoteError``, which is the peer reporting its own failure.
public enum TelepathError: Error, Sendable, Equatable {
    case invalidURL(String, reason: String)
    case unsupportedScheme(String, reason: String)
    /// The peer's protocol major version is not 3.
    case versionMismatch(theirs: [Int], ours: [Int])
    /// The handshake omitted a session iden, meaning a pre-2.166 server that only
    /// speaks task v1. Detected deliberately rather than silently degrading.
    case taskV1NotSupported
    case handshakeFailed(String)
    case protocolViolation(String)
    case connectionClosed
    case proxyClosed
    case timedOut(String)
    /// An ext code other than 0 or 1 reached the Telepath layer.
    case unexpectedExtType(Int8)
    /// A call was made on a share that has already been released.
    case shareClosed(String)

    /// An `aha://` URL was opened with no registries configured. Python keeps
    /// these in a module global loaded from `telepath.yaml`; a library cannot, so
    /// they come from `Config.ahaRegistries` and an empty list is a setup mistake.
    case ahaNoRegistries(service: String)
    /// Every registry was reachable and none of them had the service online.
    /// Distinct from a registry failing, because the two want different fixes.
    case ahaLookupFailed(service: String)
    /// The name resolved to an AHA *pool* rather than a single service.
    ///
    /// A pool has no single session, so it is not a ``Proxy``; open it with
    /// ``AHAPool`` instead. Connecting to one member as if it were the service
    /// would silently ignore the rest.
    case ahaIsAPool(name: String)
    /// An ``AHAPool`` was opened for a name that is a single service, not a pool.
    case ahaIsNotAPool(name: String)
    /// `?mirror=` was asked for, but the registry predates the `filters` argument
    /// (Synapse 2.95.0). Dropping the request would return the leader while the
    /// caller believed they had asked for a mirror.
    case ahaMirrorUnsupported(registry: String, version: [Int]?)
}
