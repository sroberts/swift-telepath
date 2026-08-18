import MsgpackFuzzCore
import Testing
@testable import Msgpack

/// Fast, seeded slices of what `msgpack-fuzz` runs at length. Fixed seeds keep CI
/// deterministic; a failure here replays with `swift run msgpack-fuzz --seed N`.
struct PropertyTests {
    static let seeds: [UInt64] = [1, 7, 42, 1337, 99991]

    @Test("generated values round-trip", arguments: PropertyTests.seeds)
    func roundTrip(seed: UInt64) throws {
        var rng = SeededRandom(seed: seed)
        for _ in 0..<2_000 {
            try FuzzChecks.roundTrip(FuzzGenerator.value(using: &rng))
        }
    }

    /// The decoder must reject or accept arbitrary bytes, never misbehave.
    @Test("arbitrary bytes never destabilise the decoder", arguments: PropertyTests.seeds)
    func arbitraryBytes(seed: UInt64) throws {
        var rng = SeededRandom(seed: seed)
        for _ in 0..<2_000 {
            let count = Int.random(in: 0...64, using: &rng)
            try FuzzChecks.arbitraryBytes(FuzzGenerator.randomBytes(count: count, using: &rng))
        }
    }

    /// Mutating a valid message is where a decoder is most likely to walk off a buffer.
    @Test("mutated valid messages never destabilise the decoder", arguments: PropertyTests.seeds)
    func mutatedMessages(seed: UInt64) throws {
        var rng = SeededRandom(seed: seed)
        for _ in 0..<1_000 {
            var bytes = MsgpackPacker.encode(FuzzGenerator.value(using: &rng))
            guard !bytes.isEmpty else { continue }
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            try FuzzChecks.arbitraryBytes(bytes)
        }
    }

    /// The property the link depends on: chunk boundaries must not change results.
    @Test("chunked streaming matches whole-buffer decoding", arguments: PropertyTests.seeds)
    func chunkedStreaming(seed: UInt64) throws {
        var rng = SeededRandom(seed: seed)
        for _ in 0..<200 {
            let batch = (0..<4).map { _ in FuzzGenerator.value(using: &rng) }
            try FuzzChecks.chunkedStream(batch, chunkSize: Int.random(in: 1...32, using: &rng))
        }
    }
}

/// Regression tests for defects the fuzzer found. Kept as explicit cases so they
/// stay covered without depending on a seed reproducing them.
struct IntegerEqualityTests {
    /// msgpack draws no wire distinction between signed and unsigned integers, so a
    /// value encoded from `.int` decodes as `.uint`. Case-sensitive equality made a
    /// decoded value unequal to the value that produced it.
    @Test("non-negative integers compare equal across int and uint cases")
    func intUintEquality() {
        #expect(MsgpackValue.int(0) == MsgpackValue.uint(0))
        #expect(MsgpackValue.int(5) == MsgpackValue.uint(5))
        #expect(MsgpackValue.int(Int64.max) == MsgpackValue.uint(UInt64(Int64.max)))
        #expect(MsgpackValue.int(-1) != MsgpackValue.uint(1))
        #expect(MsgpackValue.uint(UInt64.max) != MsgpackValue.int(-1))
    }

    @Test("equal integers hash equally, so they collapse as map keys")
    func hashingAgrees() {
        var map: [MsgpackValue: String] = [:]
        map[.int(7)] = "signed"
        map[.uint(7)] = "unsigned"
        #expect(map.count == 1, "the same number must not occupy two slots")
        #expect(map[.int(7)] == "unsigned")
    }

    /// A big integer that happens to fit in 64 bits is still the same number.
    @Test("bigInt compares equal to a narrow integer of the same value")
    func bigIntEquality() {
        #expect(MsgpackValue.bigInt(sign: .plus, magnitude: [0x05]) == MsgpackValue.uint(5))
        #expect(MsgpackValue.bigInt(sign: .minus, magnitude: [0x05]) == MsgpackValue.int(-5))
        #expect(MsgpackValue.bigInt(sign: .plus, magnitude: []) == MsgpackValue.int(0))
        // Zero has no sign.
        #expect(MsgpackValue.bigInt(sign: .minus, magnitude: []) == MsgpackValue.uint(0))
    }

    @Test("integers are not equal to other types")
    func noCrossTypeEquality() {
        #expect(MsgpackValue.int(5) != MsgpackValue.double(5.0))
        #expect(MsgpackValue.int(5) != MsgpackValue.string("5"))
        #expect(MsgpackValue.uint(1) != MsgpackValue.bool(true))
    }

    /// Decoding really does produce the case the wire implies, which is what made
    /// case-sensitive equality a trap in the first place.
    @Test("a value encoded from .int decodes as .uint but stays equal")
    func decodedCaseDiffers() throws {
        let original = MsgpackValue.int(128)
        let decoded = try MsgpackUnpacker.decode(MsgpackPacker.encode(original))
        guard case .uint = decoded else {
            Issue.record("expected the wire format to imply .uint, got \(decoded)")
            return
        }
        #expect(decoded == original)
    }
}
