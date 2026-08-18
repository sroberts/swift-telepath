# swift-telepath

A SwiftNIO client for **Telepath**, the msgpack RPC protocol that fronts every
Synapse service (Cortex, Axon, AHA, JsonStor).

Protocol version `(3, 0)`, task v2. Conformance is pinned to Synapse **2.249.0**.
Swift 6 strict concurrency, macOS 14+ / iOS 17+.

> **Status: MVP.** Connect, call, and stream against a real Cortex over `tcp://`,
> `unix://`, and `cell://`. TLS, dynamic shares, and `aha://` are not implemented
> yet — see [Not yet implemented](#not-yet-implemented).

## Usage

```swift
import Synapse

let cortex = try await Cortex.open("tcp://root:secret@cortex.example.com:27492/")
defer { await cortex.close() }

// Typed unary call
let info = try await cortex.getCellInfo()
print(info.versionString ?? "unknown")

// A value computed by the server
let count = try await cortex.callStorm("return($lib.len($lib.list(1,2,3)))", returning: Int.self)

// Stream nodes; the query runs as you iterate, not all at once
for try await node in cortex.nodes("inet:ipv4=8.8.8.8 -> inet:dns:a") {
    print(node.form, node.value, node.tags.keys)
}

// The full message stream when prints, warnings and progress matter
for try await message in cortex.storm("[ inet:fqdn=example.com ]") {
    switch message {
    case .node(let node):   print("node:", node.form)
    case .print(let text):  print(text)
    case .warn(let warn):   print("warn:", warn.mesg)
    case .finished(let f):  print("done, \(f.count) nodes")
    default: break
    }
}
```

Below the facade, `Proxy` exposes the protocol directly:

```swift
let proxy = try await Proxy.open("cell:///srv/cortex00")
let value = try await proxy.call("getCellInfo")
for try await item in proxy.stream("storm", [.string("inet:ipv4")], kwargs: ["opts": .map([:])]) { ... }
```

## Building and testing

```sh
swift build
swift test                                   # unit tests only; integration is skipped
swift test --filter VectorTests              # one suite
swift test --filter DecoderTests.overflow    # one test
```

Integration tests need a live Cortex and are skipped unless `TELEPATH_TEST_URL`
is set:

```sh
./scripts/setup-test-env.sh                  # one-time: uv venv with pinned Synapse
./scripts/run-test-cortex.sh &               # local Cortex on 127.0.0.1:27492
.venv-synapse/bin/python -m synapse.tools.service.moduser \
    --svcurl "cell://$PWD/.testcortex/cortex00" --passwd s3cret root

TELEPATH_TEST_URL="tcp://root:s3cret@127.0.0.1:27492/" swift test
```

## Conformance

Telepath has no published specification — it is defined by its Python
implementation. Four things stand in for a spec:

**Codec vectors.** `tools/genvectors.py` imports `synapse.lib.msgpack` and emits
the exact bytes Synapse produces for boundary cases: 64-bit integer limits, ext
type 0/1 big integers, `str` versus `bytes`, lone surrogates, non-string map keys,
and float edge cases. The Swift suite replays each in both directions.

```sh
.venv-synapse/bin/python tools/genvectors.py > Tests/MsgpackTests/vectors.json
```

**Integration tests.** The suite runs against a real Cortex, covering the
handshake, unary calls, generators, remote exceptions, concurrency above the pool
high water mark, and early generator abandonment.

**Recorded exchanges.** `tools/capture.py` proxies a real client-server session,
decoding both directions with Synapse's own unpacker, and writes
`Tests/TelepathTests/protocol-vectors.json`. `ReplayTests` drives the client using
only those recorded bytes, so parsing is tested against what a server actually
sent rather than against my reading of the protocol. The corpus deliberately
includes `t2:share`, which this client does not implement yet.

```sh
python tools/capture.py --listen 27493 --upstream 127.0.0.1:27492 \
    --out Tests/TelepathTests/protocol-vectors.json --label unary-call
# then point the client at 127.0.0.1:27493 and exercise the scenario
```

**Fuzzing.** `msgpack-fuzz` generates values weighted toward the cases that break
codecs, mutates valid messages, feeds arbitrary bytes to the decoder, and checks
chunked streaming. Failures print the seed needed to replay them.

```sh
swift run -c release msgpack-fuzz --seconds 3600      # spec M0 exit criteria
swift run -c release msgpack-fuzz --seed 42 --iterations 1000
```

`PropertyTests` runs seeded slices of the same checks in the normal suite, so CI
catches regressions without an hour-long job.

Re-run all of these on every Synapse minor release. `features` entries and
`sharinfo` contents change between releases even though the protocol major
version has been 3 for years.

## CI

| Workflow | Runs | Covers |
|---|---|---|
| `ci.yml` | push, pull request | build and unit tests (macOS + Linux); integration over `tcp` and `cell` against a pinned Cortex; integration against the published `vertexproject/synapse-cortex` image; a two-minute fuzz |
| `nightly.yml` | daily | one-hour fuzz; a 131k-node stream under an RSS ceiling |
| `drift.yml` | weekly | regenerates vectors against the newest Synapse and opens an issue on any change |

Integration suites skip themselves when `TELEPATH_TEST_URL` is unset, which is
convenient locally and dangerous in CI — a job that forgot to start a Cortex would
report green having tested no protocol code. CI sets
`TELEPATH_REQUIRE_INTEGRATION=1`, which turns a missing server into a failure
instead of a skip.

## Why the codec is hand-written

Synapse's packer deviates from stock msgpack in two ways that no off-the-shelf
Swift package handles:

- **Big integers.** Values outside the 64-bit range are carried as ext type 0
  (unsigned) or ext type 1 (signed two's complement). Ext 1's width comes from
  Python's `(bit_length + 8) // 8`, which is deliberately not minimal — `-2**127`
  occupies 17 bytes where 16 would do, and that padding is part of the wire format.
- **`unicode_errors='surrogatepass'`.** Strings may contain UTF-8-encoded lone
  surrogates that Swift's `String` cannot represent. These decode to
  `MsgpackValue.rawString` and round-trip byte for byte, because failing a whole
  message over one dirty property would make the library unusable against real
  Cortex data.

## Design decisions

**Non-UTF-8 strings repair by default.** Decoding a `.rawString` into a `String`
property substitutes U+FFFD; `MsgpackDecoder.stringDecodingStrategy = .throw`
opts into strict behavior. Intelligence data is dirty and callers overwhelmingly
want the query to finish. The exact bytes stay reachable via
`MsgpackValue.stringBytes`, or by typing the property as `[UInt8]`/`MsgpackValue`.

**Integers compare numerically, not by case.** msgpack draws no wire distinction
between a signed and an unsigned integer, so a value encoded from `.int(5)`
decodes as `.uint(5)`. With a derived `Equatable` that made a decoded value
unequal to the value that produced it, which is a trap for anyone asserting on a
result. `Equatable` and `Hashable` are hand-written and treat `.int`, `.uint`, and
`.bigInt` as equal whenever they denote the same number. Found by fuzzing.

**Maps do not round-trip byte-exactly.** Swift's `Dictionary` does not preserve
insertion order, so a re-encoded map permutes its keys. msgpack maps are
semantically unordered and Synapse unpacks them into a `dict`, so this carries no
protocol meaning — but it does mean the bytes are not reproducible for anything
that hashes a packed map. Everything else re-encodes byte for byte.

**Abandoned generators close their link.** Synapse closes rather than draining,
and so does this client: reading an unbounded Storm result set to recycle a socket
costs far more than opening a new connection.

**Backpressure is real, not buffered.** Links disable `autoRead` and issue reads
only when a consumer is waiting, so a slow consumer applies backpressure to the
server instead of filling a userspace buffer.

## Not yet implemented

- **TLS** (`ssl://`), certificate pinning by `certhash`, and Synapse cert
  directories. `ssl://` URLs parse but connecting throws.
- **Dynamic shares** (`t2:share`). Detected and reported, not supported.
- **`aha://` resolution**, mirror pools, `dynmirror`.
- **Pool low-water prefill.** Links are opened on demand and culled above the high
  water mark; Synapse's background refill to 4 idle links is not replicated.
- **Reconnect.** A dropped main link surfaces as an error rather than
  re-handshaking. Deliberate: silently re-handshaking loses server-side share
  state and would loop after a credential rotation.
- **`Config.callTimeout`.** Declared but not enforced; a call currently waits
  indefinitely. `Config.poolLowWater` is likewise inert.
- **Server side.** Out of scope.
