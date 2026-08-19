import Msgpack
import Telepath

/// A Synapse user, as returned by the auth APIs.
public struct SynapseUser: Sendable, Decodable {
    public let iden: String
    public let name: String
    public let admin: Bool?
    public let locked: Bool?
    public let archived: Bool?
    public let email: String?
    /// Roles the user holds, as full definitions rather than idens. Every user
    /// carries the implicit `all` role in addition to any granted ones.
    public let roles: [SynapseRole]?

    enum CodingKeys: String, CodingKey {
        case iden, name, admin, locked, archived, email, roles
    }
}

public struct SynapseRole: Sendable, Decodable {
    public let iden: String
    public let name: String
}

extension SynapseUser {
    public func hasRole(iden: String) -> Bool {
        roles?.contains { $0.iden == iden } ?? false
    }
}

/// User and role administration.
///
/// Thin by design: these forward to the cell's own methods rather than
/// reimplementing policy, so the names match what `synapse.tools.service.moduser`
/// and the Storm `$lib.auth` APIs operate on.
extension Cortex {
    /// The user this session is authenticated as.
    ///
    /// Useful for confirming which identity a TLS client certificate produced,
    /// since that is the certificate's common name rather than the URL's user.
    public func getCellUser() async throws -> SynapseUser {
        try await proxy.call("getCellUser", returning: SynapseUser.self)
    }

    public func getUserDefs() async throws -> [SynapseUser] {
        try await proxy.call("getUserDefs", returning: [SynapseUser].self)
    }

    public func getUserDef(iden: String) async throws -> SynapseUser? {
        let value = try await proxy.call("getUserDef", [.string(iden)])
        guard !value.isNull else { return nil }
        return try MsgpackDecoder().decode(SynapseUser.self, from: value)
    }

    public func getUserDef(name: String) async throws -> SynapseUser? {
        let value = try await proxy.call("getUserDefByName", [.string(name)])
        guard !value.isNull else { return nil }
        return try MsgpackDecoder().decode(SynapseUser.self, from: value)
    }

    @discardableResult
    public func addUser(_ name: String, password: String? = nil, email: String? = nil) async throws -> SynapseUser {
        var kwargs: [String: MsgpackValue] = [:]
        if let password { kwargs["passwd"] = .string(password) }
        if let email { kwargs["email"] = .string(email) }
        let value = try await proxy.call("addUser", [.string(name)], kwargs: kwargs)
        return try MsgpackDecoder().decode(SynapseUser.self, from: value)
    }

    public func deleteUser(iden: String) async throws {
        _ = try await proxy.call("delUser", [.string(iden)])
    }

    public func setUserPassword(iden: String, password: String?) async throws {
        _ = try await proxy.call("setUserPasswd", [.string(iden), password.map { .string($0) } ?? .null])
    }

    public func setUserAdmin(iden: String, _ admin: Bool) async throws {
        _ = try await proxy.call("setUserAdmin", [.string(iden), .bool(admin)])
    }

    public func setUserLocked(iden: String, _ locked: Bool) async throws {
        _ = try await proxy.call("setUserLocked", [.string(iden), .bool(locked)])
    }

    /// Whether a user is permitted a rule, which is how Synapse expresses
    /// authorisation — a dotted permission path such as `node.add`.
    public func isUserAllowed(iden: String, permission: [String], gateIden: String? = nil) async throws -> Bool {
        var args: [MsgpackValue] = [.string(iden), .array(permission.map { .string($0) })]
        if let gateIden { args.append(.string(gateIden)) }
        return try await proxy.call("isUserAllowed", args).boolValue ?? false
    }

    // MARK: - Roles

    public func getRoleDefs() async throws -> [SynapseRole] {
        try await proxy.call("getRoleDefs", returning: [SynapseRole].self)
    }

    @discardableResult
    public func addRole(_ name: String) async throws -> SynapseRole {
        try await proxy.call("addRole", [.string(name)], returning: SynapseRole.self)
    }

    public func deleteRole(iden: String) async throws {
        _ = try await proxy.call("delRole", [.string(iden)])
    }

    public func addUserRole(userIden: String, roleIden: String) async throws {
        _ = try await proxy.call("addUserRole", [.string(userIden), .string(roleIden)])
    }

    public func deleteUserRole(userIden: String, roleIden: String) async throws {
        _ = try await proxy.call("delUserRole", [.string(userIden), .string(roleIden)])
    }
}
