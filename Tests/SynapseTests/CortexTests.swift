import Foundation
import Msgpack
import Synapse
import Telepath
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TELEPATH_TEST_URL"] != nil))
struct CortexTests {
    private func withCortex<T>(_ body: (Cortex) async throws -> T) async throws -> T {
        let cortex = try await Cortex.open(ProcessInfo.processInfo.environment["TELEPATH_TEST_URL"]!)
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

/// Volume test for the NIO-to-AsyncSequence boundary. Reads are issued explicitly
/// rather than buffered, so a large result set must stream at bounded memory.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TELEPATH_TEST_URL"] != nil))
struct StreamVolumeTests {
    @Test("a large query streams to completion", .timeLimit(.minutes(2)))
    func largeStream() async throws {
        let cortex = try await Cortex.open(ProcessInfo.processInfo.environment["TELEPATH_TEST_URL"]!)
        defer { Task { await cortex.close() } }

        // A /20 is 4096 addresses: enough to cross many socket reads.
        var seen = 0
        for try await node in cortex.nodes("[ inet:ipv4=10.20.0.0/20 ]") {
            #expect(node.form == "inet:ipv4")
            seen += 1
        }
        #expect(seen == 4096)
    }
}
