import Testing
@testable import Msgpack

struct DecoderTests {
    struct Person: Decodable, Equatable {
        let name: String
        let age: Int
        let tags: [String]
        let active: Bool
    }

    @Test("a keyed model decodes")
    func keyed() throws {
        let value = MsgpackValue.map([
            .string("name"): .string("alice"),
            .string("age"): .uint(42),
            .string("tags"): .array([.string("a"), .string("b")]),
            .string("active"): .bool(true),
        ])
        let person = try MsgpackDecoder().decode(Person.self, from: value)
        #expect(person == Person(name: "alice", age: 42, tags: ["a", "b"], active: true))
    }

    @Test("optionals tolerate missing and null values")
    func optionals() throws {
        struct Model: Decodable { let present: String?; let absent: String?; let explicit: String? }
        let value = MsgpackValue.map([.string("present"): .string("x"), .string("explicit"): .null])
        let model = try MsgpackDecoder().decode(Model.self, from: value)
        #expect(model.present == "x")
        #expect(model.absent == nil)
        #expect(model.explicit == nil)
    }

    /// MsgpackValue decodes to itself so a caller can keep an arbitrary subtree —
    /// or one with dirty strings — without pre-declaring its shape.
    @Test("MsgpackValue passes through a Decodable model")
    func passthrough() throws {
        struct Model: Decodable { let meta: MsgpackValue }
        let value = MsgpackValue.map([.string("meta"): .array([.uint(1), .string("two")])])
        let model = try MsgpackDecoder().decode(Model.self, from: value)
        #expect(model.meta == .array([.uint(1), .string("two")]))
    }

    /// The surrogatepass policy. Intelligence data is dirty and callers
    /// overwhelmingly want the query to finish, so the default is lossy repair;
    /// strict mode is available when a caller would rather know.
    @Test("a non-UTF8 string is repaired by default and throws in strict mode")
    func rawStringPolicy() throws {
        struct Model: Decodable { let value: String }
        let dirty = MsgpackValue.map([.string("value"): .rawString([0x61, 0xed, 0xa0, 0x80, 0x62])])

        let lenient = try MsgpackDecoder().decode(Model.self, from: dirty)
        #expect(lenient.value.contains("a"))
        #expect(lenient.value.contains("\u{FFFD}"), "invalid bytes become the replacement character")

        var strict = MsgpackDecoder()
        strict.stringDecodingStrategy = .throw
        #expect(throws: MsgpackError.self) { try strict.decode(Model.self, from: dirty) }
    }

    /// The bytes remain reachable, which is what makes the lossy default safe.
    @Test("raw bytes stay available when a model asks for them")
    func rawBytesAccessible() throws {
        let dirty = MsgpackValue.rawString([0x61, 0xed, 0xa0, 0x80])
        #expect(dirty.stringValue == nil)
        #expect(dirty.stringBytes == [0x61, 0xed, 0xa0, 0x80])
    }

    @Test("an integer too wide for the target type is reported, not truncated")
    func overflow() throws {
        struct Model: Decodable { let value: Int8 }
        let value = MsgpackValue.map([.string("value"): .uint(300)])
        #expect(throws: MsgpackError.self) { try MsgpackDecoder().decode(Model.self, from: value) }
    }

    @Test("a big integer cannot masquerade as a fixed-width one")
    func bigIntRejected() throws {
        struct Model: Decodable { let value: Int64 }
        let value = MsgpackValue.map([.string("value"): .bigInt(sign: .plus, magnitude: [1] + [UInt8](repeating: 0, count: 8))])
        #expect(throws: MsgpackError.self) { try MsgpackDecoder().decode(Model.self, from: value) }
    }

    @Test("a type mismatch names the coding path")
    func mismatchPath() throws {
        struct Inner: Decodable { let n: Int }
        struct Outer: Decodable { let inner: Inner }
        let value = MsgpackValue.map([.string("inner"): .map([.string("n"): .string("nope")])])
        do {
            _ = try MsgpackDecoder().decode(Outer.self, from: value)
            Issue.record("expected a failure")
        } catch let error as MsgpackError {
            guard case .typeMismatch(_, _, let path) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(path == "inner.n")
        }
    }
}
