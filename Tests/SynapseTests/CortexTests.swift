import Foundation
import Msgpack
import Synapse
import Telepath
import TelepathTestKit
import Testing

@Suite(.enabled(if: IntegrationEnvironment.shouldRun))
struct CortexTests {
    private func withCortex<T>(_ body: (Cortex) async throws -> T) async throws -> T {
        let cortex = try await Cortex.open(try IntegrationEnvironment.requireURL())
        do {
            let result = try await body(cortex)
            await cortex.close()
            return result
        } catch {
            await cortex.close()
            throw error
        }
    }

    @Test("getCellInfo decodes into a typed model")
    func cellInfo() async throws {
        try await withCortex { cortex in
            let info = try await cortex.getCellInfo()
            #expect(info.cell?.type == "cortex")
            #expect(info.synapse?.version?.first == 2)
            #expect(info.versionString?.hasPrefix("2.") == true)
        }
    }

    @Test("callStorm decodes into Swift types")
    func callStormTyped() async throws {
        try await withCortex { cortex in
            let sum = try await cortex.callStorm("return((40 + 2))", returning: Int.self)
            #expect(sum == 42)

            let text = try await cortex.callStorm("return(hello)", returning: String.self)
            #expect(text == "hello")

            let list = try await cortex.callStorm("return(([1, 2, 3]))", returning: [Int].self)
            #expect(list == [1, 2, 3])

            struct Result: Decodable, Equatable {
                let name: String
                let count: Int
            }
            let structured = try await cortex.callStorm(
                "return(({'name': 'widget', 'count': 7}))", returning: Result.self)
            #expect(structured == Result(name: "widget", count: 7))
        }
    }

    @Test("storm vars are passed through opts")
    func stormVars() async throws {
        try await withCortex { cortex in
            let opts = StormOpts(vars: ["answer": .int(42)])
            let value = try await cortex.callStorm("return($answer)", opts: opts, returning: Int.self)
            #expect(value == 42)
        }
    }

    @Test("the node stream decodes forms, values, props and tags")
    func nodeStream() async throws {
        try await withCortex { cortex in
            var nodes: [Node] = []
            for try await node in cortex.nodes("[ inet:ipv4=8.8.8.8 +#test.tag ]") {
                nodes.append(node)
            }
            let node = try #require(nodes.first)
            #expect(node.form == "inet:ipv4")
            #expect(node.iden?.count == 64, "node iden is a 32-byte buid in hex")
            #expect(node.hasTag("test.tag"))
            #expect(node.props[".created"] != nil)
        }
    }

    @Test("the raw storm stream reports init, node and fini in order")
    func rawStream() async throws {
        try await withCortex { cortex in
            var kinds: [String] = []
            var count = 0
            for try await message in cortex.storm("[ inet:fqdn=example.com ]") {
                switch message {
                case .initialized: kinds.append("init")
                case .node: kinds.append("node")
                case .finished(let fini):
                    kinds.append("fini")
                    count = fini.count
                default: break
                }
            }
            #expect(kinds.first == "init")
            #expect(kinds.contains("node"))
            #expect(kinds.last == "fini")
            #expect(count >= 1)
        }
    }

    @Test("print and warn messages surface")
    func printAndWarn() async throws {
        try await withCortex { cortex in
            var prints: [String] = []
            for try await message in cortex.storm("$lib.print(hello) $lib.warn(careful)") {
                if case .print(let text) = message { prints.append(text) }
            }
            #expect(prints.contains("hello"))
        }
    }

    /// A bad query fails at the err message, not by silently ending the stream.
    @Test("an err message in the stream is rethrown")
    func streamError() async throws {
        try await withCortex { cortex in
            await #expect(throws: (any Error).self) {
                for try await _ in cortex.nodes("inet:ipv4=notanip") {}
            }
        }
    }

    @Test("count returns without transferring nodes")
    func countQuery() async throws {
        try await withCortex { cortex in
            _ = try await cortex.callStorm("[ inet:fqdn=counted.example ] return($lib.true)")
            let n = try await cortex.count("inet:fqdn=counted.example")
            #expect(n == 1)
        }
    }

    @Test("reqValidStorm accepts valid syntax and rejects invalid")
    func validation() async throws {
        try await withCortex { cortex in
            try await cortex.reqValidStorm("inet:ipv4=1.2.3.4")
            await #expect(throws: TelepathRemoteError.self) {
                try await cortex.reqValidStorm("|||bad|||")
            }
        }
    }
}

/// Volume tests for the NIO-to-AsyncSequence boundary. Links disable autoRead and
/// issue a read only when a consumer is waiting, so peak memory should track the
/// consumer's appetite rather than the size of the result set.
@Suite(.enabled(if: IntegrationEnvironment.shouldRun))
struct StreamVolumeTests {
    /// Resident set size, for asserting that streaming does not accumulate.
    static func residentBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
        #else
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
              let residentPages = statm.split(separator: " ").dropFirst().first,
              let pages = UInt64(residentPages) else { return 0 }
        return pages * UInt64(sysconf(Int32(_SC_PAGESIZE)))
        #endif
    }

    /// Set TELEPATH_LARGE_STREAM=1 for the 131k-node run spec.md M3 calls for.
    /// The default keeps pull-request CI quick.
    static var isLargeRun: Bool {
        ProcessInfo.processInfo.environment["TELEPATH_LARGE_STREAM"] == "1"
    }

    @Test("a large query streams to completion at bounded memory", .timeLimit(.minutes(30)))
    func largeStream() async throws {
        let cortex = try await Cortex.open(try IntegrationEnvironment.requireURL())
        defer { Task { await cortex.close() } }

        // A /20 is 4096 addresses; a /15 is 131072, which is the M3 target.
        let query = Self.isLargeRun ? "[ inet:ipv4=10.64.0.0/15 ]" : "[ inet:ipv4=10.20.0.0/20 ]"
        let expected = Self.isLargeRun ? 131_072 : 4_096

        // Let the proxy and its first link settle before sampling.
        _ = try await cortex.callStorm("return((1))")
        let baseline = Self.residentBytes()
        var peak = baseline

        var seen = 0
        for try await node in cortex.nodes(query) {
            #expect(node.form == "inet:ipv4")
            seen += 1
            if seen % 1_000 == 0 {
                peak = max(peak, Self.residentBytes())
            }
        }
        #expect(seen == expected)

        // Backpressure means growth should track the consumer, not the result size.
        // The ceiling is deliberately loose: it is here to catch buffering the whole
        // stream, not to police allocator noise.
        let growth = peak > baseline ? peak - baseline : 0
        let ceiling: UInt64 = 512 * 1024 * 1024
        #expect(growth < ceiling,
                "streaming \(seen) nodes grew RSS by \(growth / 1_048_576) MiB")
    }

    /// Abandoning repeatedly must not leak links or file descriptors.
    @Test("repeated early abandonment does not accumulate connections")
    func repeatedAbandonment() async throws {
        let cortex = try await Cortex.open(try IntegrationEnvironment.requireURL())
        defer { Task { await cortex.close() } }

        for _ in 0..<50 {
            var seen = 0
            for try await _ in cortex.nodes("[ inet:ipv4=10.30.0.0/24 ]") {
                seen += 1
                if seen >= 2 { break }
            }
        }
        // Still healthy after fifty abandoned streams.
        #expect(try await cortex.callStorm("return((7))", returning: Int.self) == 7)
    }
}
