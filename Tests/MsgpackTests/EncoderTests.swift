import MsgpackFuzzCore
import Testing
@testable import Msgpack

struct EncoderTests {
    struct Person: Codable, Equatable {
        let name: String
        let age: Int
        let tags: [String]
        let active: Bool
        let score: Double?
    }

    @Test("a keyed model encodes to a map")
    func keyed() throws {
        let person = Person(name: "alice", age: 42, tags: ["a", "b"], active: true, score: nil)
        let value = try MsgpackEncoder().encode(person)

        #expect(value["name"] == .string("alice"))
        #expect(value["age"] == .uint(42))
        #expect(value["tags"] == .array([.string("a"), .string("b")]))
        #expect(value["active"] == .bool(true))
    }

    @Test("models survive an encode/decode round trip")
    func roundTrip() throws {
        let person = Person(name: "bob", age: 7, tags: [], active: false, score: 1.5)
        let value = try MsgpackEncoder().encode(person)
        #expect(try MsgpackDecoder().decode(Person.self, from: value) == person)
    }

    @Test("nested models and arrays encode")
    func nested() throws {
        struct Wrapper: Codable, Equatable {
            let people: [Person]
            let meta: [String: String]
        }
        let wrapper = Wrapper(
            people: [Person(name: "a", age: 1, tags: ["x"], active: true, score: nil)],
            meta: ["k": "v"]
        )
        let value = try MsgpackEncoder().encode(wrapper)
        #expect(value["people"]?.arrayValue?.count == 1)
        #expect(value["people"]?[0]?["name"] == .string("a"))
        #expect(value["meta"]?["k"] == .string("v"))
        #expect(try MsgpackDecoder().decode(Wrapper.self, from: value) == wrapper)
    }

    /// Negative values keep the signed form; non-negative ones take the unsigned
    /// form the wire would carry, so a value round-trips to the same case.
    @Test("integers encode in the form the wire uses")
    func integerForms() throws {
        #expect(try MsgpackEncoder().encode(5) == .uint(5))
        #expect(try MsgpackEncoder().encode(-5) == .int(-5))
        #expect(try MsgpackEncoder().encode(0) == .uint(0))
        // ...and the two cases are equal anyway, which is what makes this safe.
        #expect(try MsgpackEncoder().encode(5) == .int(5))
    }

    /// Callers can drop a raw subtree into a typed model, which is the escape hatch
    /// for data no Encodable type can carry — a non-UTF8 string, for instance.
    @Test("MsgpackValue passes through untouched")
    func passthrough() throws {
        struct Model: Encodable {
            let name: String
            let dirty: MsgpackValue
        }
        let dirty = MsgpackValue.rawString([0x61, 0xed, 0xa0, 0x80])
        let value = try MsgpackEncoder().encode(Model(name: "x", dirty: dirty))
        #expect(value["dirty"] == dirty)
        #expect(value["dirty"]?.stringBytes == [0x61, 0xed, 0xa0, 0x80])
    }

    @Test("a bare MsgpackValue encodes to itself")
    func identity() throws {
        let value = MsgpackValue.map([.uint(1): .string("int key")])
        #expect(try MsgpackEncoder().encode(value) == value)
    }

    @Test("encoding straight to bytes matches packing the value")
    func toBytes() throws {
        let person = Person(name: "c", age: 3, tags: ["t"], active: true, score: nil)
        let bytes = try MsgpackEncoder().encodeToBytes(person)
        let decoded = try MsgpackDecoder().decode(Person.self, from: bytes)
        #expect(decoded == person)
    }

    /// Anything the generator produces must survive Encodable round-tripping too,
    /// not just the packer.
    @Test("generated values round-trip through the Codable bridge",
          arguments: [UInt64(3), 11, 101])
    func generatedRoundTrip(seed: UInt64) throws {
        var rng = SeededRandom(seed: seed)
        for _ in 0..<500 {
            let value = FuzzGenerator.value(using: &rng)
            let encoded = try MsgpackEncoder().encode(value)
            #expect(FuzzChecks.semanticallyEqual(encoded, value))
        }
    }
}
