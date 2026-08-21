import Msgpack
import Synapse
import Testing

/// `getCellInfo` is otherwise only exercised against a live server, which reports
/// exactly one version shape per release. These decode the shapes directly so the
/// leniency does not depend on which Synapse happens to be running.
@Suite struct CellInfoDecodingTests {
    private func decode(version: MsgpackValue?, commit: MsgpackValue? = nil) throws -> CellInfo {
        var synapse: [MsgpackValue: MsgpackValue] = [:]
        if let version { synapse[.string("version")] = version }
        if let commit { synapse[.string("commit")] = commit }
        let value = MsgpackValue.map([
            .string("cell"): .map([.string("type"): .string("cortex")]),
            .string("synapse"): .map(synapse),
        ])
        return try MsgpackDecoder().decode(CellInfo.self, from: value)
    }

    @Test("a 2.x tuple version decodes")
    func tuple() throws {
        let info = try decode(version: .array([.uint(2), .uint(249), .uint(0)]))
        #expect(info.synapse?.version == [2, 249, 0])
        #expect(info.versionString == "2.249.0")
    }

    @Test("a 3.0 dotted-string version decodes")
    func string() throws {
        let info = try decode(version: .string("3.0.0"))
        #expect(info.synapse?.version == [3, 0, 0])
        #expect(info.versionString == "3.0.0")
    }

    /// The point of the leniency: a shape nobody anticipated must leave one field
    /// nil rather than fail the call that carries it. Reading only the tuple is
    /// what broke `getCellInfo` against 3.0 in the first place.
    @Test("an unanticipated version shape yields nil rather than throwing")
    func unknownShape() throws {
        let info = try decode(version: .map([.string("major"): .uint(3)]))
        #expect(info.synapse?.version == nil)
        #expect(info.cell?.type == "cortex", "the rest of the payload must survive")
    }

    @Test("a non-string commit yields nil rather than throwing")
    func unknownCommitShape() throws {
        let info = try decode(version: .string("3.0.0"), commit: .uint(42))
        #expect(info.synapse?.commit == nil)
        #expect(info.synapse?.version == [3, 0, 0])
    }

    @Test("a missing version is nil")
    func absent() throws {
        let info = try decode(version: nil)
        #expect(info.synapse?.version == nil)
    }

    @Test("a version that is not purely numeric is nil, not a partial parse")
    func prerelease() throws {
        let info = try decode(version: .string("3.0.0-rc1"))
        #expect(info.synapse?.version == nil)
    }
}
