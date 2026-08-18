import Msgpack
import MsgpackFuzzCore
import Foundation

/// Long-running fuzz driver for the msgpack codec.
///
/// spec.md M0 requires a fuzz target that runs an hour clean. Every failure prints
/// the seed and iteration that produced it, so any crash is reproducible with
/// `--seed <n>`.
///
///   swift run -c release msgpack-fuzz --seconds 3600
///   swift run -c release msgpack-fuzz --seed 12345 --iterations 1000

struct Options {
    var seconds: Double?
    var iterations: Int?
    var seed: UInt64 = 1
    var quiet = false
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let flag = arguments.first {
        arguments.removeFirst()
        switch flag {
        case "--seconds": options.seconds = arguments.first.flatMap(Double.init); arguments.removeFirst()
        case "--iterations": options.iterations = arguments.first.flatMap(Int.init); arguments.removeFirst()
        case "--seed": options.seed = arguments.first.flatMap(UInt64.init) ?? 1; arguments.removeFirst()
        case "--quiet": options.quiet = true
        case "--help":
            print("""
            usage: msgpack-fuzz [--seconds N] [--iterations N] [--seed N] [--quiet]

              --seconds N     run for N seconds (default 10 when no iterations given)
              --iterations N  run exactly N iterations
              --seed N        starting seed; a reported failure replays from here
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(flag)\n".utf8))
            exit(2)
        }
    }
    if options.seconds == nil && options.iterations == nil { options.seconds = 10 }
    return options
}

let options = parseOptions()
let start = Date()
var iteration = 0
var failures = 0
var rng = SeededRandom(seed: options.seed)

@MainActor func shouldContinue() -> Bool {
    if let iterations = options.iterations { return iteration < iterations }
    if let seconds = options.seconds { return Date().timeIntervalSince(start) < seconds }
    return false
}

@MainActor func report(_ failure: any Error, iteration: Int) {
    failures += 1
    let text = """
    FAIL at iteration \(iteration) (replay with --seed \(options.seed))
    \(failure)

    """
    FileHandle.standardError.write(Data(text.utf8))
}

var lastProgress = Date()

while shouldContinue() {
    iteration += 1

    // 1. Structured round-trip: a generated value must survive encode/decode and
    //    re-encode to identical bytes.
    let value = FuzzGenerator.value(using: &rng)
    do {
        try FuzzChecks.roundTrip(value)
    } catch {
        report(error, iteration: iteration)
    }

    // 2. Arbitrary bytes: the decoder must reject or accept, never misbehave.
    let length = Int.random(in: 0...64, using: &rng)
    let noise = FuzzGenerator.randomBytes(count: length, using: &rng)
    do {
        try FuzzChecks.arbitraryBytes(noise)
    } catch {
        report(error, iteration: iteration)
    }

    // 3. Mutated valid input: flipping bytes of a real message is where a decoder
    //    is most likely to walk off the end of a buffer.
    var mutated = MsgpackPacker.encode(value)
    if !mutated.isEmpty {
        let flips = Int.random(in: 1...3, using: &rng)
        for _ in 0..<flips {
            let index = Int.random(in: 0..<mutated.count, using: &rng)
            mutated[index] = UInt8.random(in: 0...255, using: &rng)
        }
        do {
            try FuzzChecks.arbitraryBytes(mutated)
        } catch {
            report(error, iteration: iteration)
        }
    }

    // 4. Chunked streaming: the property the link depends on.
    if iteration % 16 == 0 {
        let batch = (0..<4).map { _ in FuzzGenerator.value(using: &rng) }
        do {
            try FuzzChecks.chunkedStream(batch, chunkSize: Int.random(in: 1...32, using: &rng))
        } catch {
            report(error, iteration: iteration)
        }
    }

    if !options.quiet, Date().timeIntervalSince(lastProgress) >= 10 {
        let elapsed = Int(Date().timeIntervalSince(start))
        print("[\(elapsed)s] \(iteration) iterations, \(failures) failures")
        lastProgress = Date()
    }
}

let elapsed = Date().timeIntervalSince(start)
print("ran \(iteration) iterations in \(String(format: "%.1f", elapsed))s, \(failures) failures")
exit(failures == 0 ? 0 : 1)
