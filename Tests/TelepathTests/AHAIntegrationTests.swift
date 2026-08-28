import Foundation
import Msgpack
import TelepathTestKit
import Testing
@testable import Telepath

/// M7 and M8 against a **real** AHA registry with a real pool, started by
/// `scripts/run-aha-test-env.sh`.
///
/// The scripted-daemon suites encode what this client believes AHA does, so they
/// cannot discover that the belief is wrong. This can, and did: the pool record's
/// `services` is a dict rather than a list, a pool's `svcinfo` carries no `online`
/// key at all, and `iterPoolTopo` stays open indefinitely after replaying
/// membership rather than ending.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TELEPATH_AHA_URL"] != nil))
struct AHAIntegrationTests {
    private var registry: String {
        ProcessInfo.processInfo.environment["TELEPATH_AHA_URL"]!
    }
    private var poolName: String {
        ProcessInfo.processInfo.environment["TELEPATH_AHA_POOL"] ?? "pool.synapse"
    }
    private var serviceName: String {
        ProcessInfo.processInfo.environment["TELEPATH_AHA_SERVICE"] ?? "alpha.synapse"
    }

    private var config: Config {
        var config = Config()
        config.ahaRegistries = [registry]
        return config
    }

    // MARK: - M7

    @Test("a real AHA resolves a service to a working connection", .timeLimit(.minutes(1)))
    func resolvesAgainstRealAHA() async throws {
        let proxy = try await Proxy.open("aha://\(serviceName)", config: config)
        let info = try await proxy.call("getCellInfo")
        #expect(info["cell"]?["type"]?.stringValue == "cortex")
        await proxy.close()
    }

    /// The registry fills `user` in from the requesting user, so this is the case
    /// where taking AHA's answer over the caller's looks correct — the strings
    /// match. It is pinned against the real thing regardless.
    @Test("the resolved URL carries the registered address", .timeLimit(.minutes(1)))
    func resolvedURLIsTheRegisteredOne() async throws {
        let resolved = try await AHAResolver.resolve(
            TelepathURL("aha://\(serviceName)"),
            registries: [registry],
            logger: config.logger,
            open: { try await Proxy.open($0, config: Config()) })
        #expect(resolved.scheme == .tcp)
        #expect(resolved.host == "127.0.0.1")
        #expect(resolved.port != 0)
        // AHA rewrites urlinfo.user to the requesting user, so a resolved URL
        // carries an identity even though the caller named none.
        #expect(resolved.user == "root", "the resolved URL lost its user")
    }

    @Test("a name AHA has never heard of fails as an unknown service", .timeLimit(.minutes(1)))
    func unknownServiceAgainstRealAHA() async throws {
        do {
            _ = try await Proxy.open("aha://nosuch.synapse", config: config)
            Issue.record("expected the lookup to fail")
        } catch let error as TelepathError {
            guard case .ahaLookupFailed = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
    }

    // MARK: - M8

    /// A real pool record carries `services` as a **dict**, and its `svcinfo` has no
    /// `online` key. Detection therefore has to test `services` before `online`, or
    /// a pool reads as an offline service and is skipped.
    @Test("a real pool is recognised as a pool", .timeLimit(.minutes(1)))
    func realPoolIsRecognised() async throws {
        do {
            _ = try await Proxy.open("aha://\(poolName)", config: config)
            Issue.record("expected Proxy.open to refuse a real pool")
        } catch let error as TelepathError {
            guard case .ahaIsAPool(let name) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(name == poolName)
        }
    }

    @Test("a real pool replays its membership and serves calls", .timeLimit(.minutes(2)))
    func realPoolServesCalls() async throws {
        let pool = try await AHAPool.open("aha://\(poolName)", config: config)

        var members: [String] = []
        for _ in 0..<300 {
            members = await pool.memberNames
            if members.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(members.count == 2, "the real topology replay did not populate the pool")

        // Every member is a working Cortex, and the calls spread across them.
        var idens: Set<String> = []
        for _ in 0..<4 {
            let iden = try await pool.call("getCellIden").stringValue
            if let iden { idens.insert(iden) }
        }
        #expect(idens.count == 2, "calls did not round-robin over both members: \(idens)")
        await pool.close()
    }

    /// The behaviour a fake cannot establish: the real generator stays open after
    /// replaying, so a pool that is following it must *not* be churning through
    /// rebuilds. A rebuild drops every member, so a membership that stays stable
    /// across several seconds is the observable form of "the stream is still open".
    @Test("the real topology stream stays open rather than rebuilding", .timeLimit(.minutes(2)))
    func realTopologyStreamStaysOpen() async throws {
        let pool = try await AHAPool.open("aha://\(poolName)", config: config)
        for _ in 0..<300 {
            if await pool.memberNames.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await pool.memberNames.count == 2)

        // A pool that was rebuilding on a 1s cycle would pass through empty here.
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(250))
            #expect(await pool.memberNames.count == 2,
                    "membership dropped, so the pool is rebuilding rather than following")
        }
        await pool.close()
    }
}
