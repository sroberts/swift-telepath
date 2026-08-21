# swift-telepath

A SwiftNIO client for **Telepath**, the msgpack RPC protocol that fronts every
Synapse service (Cortex, Axon, AHA, JsonStor).

Protocol version `(3, 0)`, task v2. Conformance is pinned to Synapse **2.249.0**.
Swift 6 strict concurrency, macOS 14+ / iOS 17+. Requires a **Swift 6.2+
toolchain**, declared by the manifest's tools version: swift-nio, swift-log and
swift-certificates themselves declare 6.1 and 6.2, so an older toolchain cannot
resolve the package.

> **Status: MVP.** Connect, call, and stream against a real Cortex over `tcp://`,
> `ssl://`, `unix://`, and `cell://`, including certificate pinning and TLS client
> certificates. Dynamic shares and `aha://` are not implemented yet — see
> [Not yet implemented](#not-yet-implemented).

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

// User administration
let me = try await cortex.getCellUser()
let user = try await cortex.addUser("analyst", password: "hunter2")
try await cortex.setUserAdmin(iden: user.iden, false)

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
let typed = try await proxy.call("getCellInfo", returning: CellInfo.self)

for try await item in proxy.stream("storm", [.string("inet:ipv4")], kwargs: ["opts": .map([:])]) { ... }

// A method returning a dynamically shared object
let upload = try await proxy.callForShare("upload")
_ = try await upload.call("write", [.binary(bytes)])
_ = try await upload.call("save")
await upload.close()          // share:fini travels on the main link
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

TLS needs its own listeners and a certificate authority:

```sh
./scripts/run-tls-test-cortex.sh              # 27500 password/CA/pinning, 27501 client cert
export TELEPATH_CERT_DIR="$PWD/.testcerts"
export TELEPATH_CERT_HASH="$(cat .testcerts/certhash)"
export TELEPATH_TLS_CLIENTCERT_PORT=27501
swift test --filter TLSIntegrationTests
```

## Documentation

```sh
swift package generate-documentation --target Telepath   # build
swift package --disable-sandbox preview-documentation --target Telepath
```

CI builds DocC for every public target and fails on warnings, since a broken
symbol link reads as documented until someone follows it. To publish static HTML:

```sh
swift package --allow-writing-to-directory ./docs \
    generate-documentation --target Telepath --disable-indexing \
    --transform-for-static-hosting --hosting-base-path swift-telepath \
    --output-path ./docs
```

Hosting it on GitHub Pages needs the repository to be public, or a plan that
allows Pages on private repositories.

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

### Synapse 3.0

Synapse 3.0.0 is published and requires Python 3.14. Regenerating the vectors
against it shows every case packing byte-identically to 2.249.0 **except lone
surrogates, which 3.0 refuses to pack at all** — it dropped
`unicode_errors='surrogatepass'`, raising `NotMsgpackSafe` instead.

So the codec needs no changes for 3.0, and `MsgpackValue.rawString` becomes a
compatibility concern rather than a live one: a conformant 3.0 server cannot emit
a non-UTF-8 `str`, while 2.x servers still do. Keep decoding it, since this client
supports both, but do not expect to encode one toward a 3.0 peer.

`tools/genvectors.py` records an unpackable value as `unsupported` rather than
failing, so the drift job reports the difference instead of dying on it. Note also
that `synapse.version` changed from a tuple to a string in 3.0.

## CI

| Workflow | Runs | Covers |
|---|---|---|
| `ci.yml` | push, pull request | build and unit tests (macOS + Linux); integration over `tcp` and `cell` against a pinned Cortex; TLS integration covering CA trust, pinning and client certificates; integration against the published `vertexproject/synapse-cortex` image; a two-minute fuzz |
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

## TLS

Synapse's TLS behaviour is deliberately not standard, because its services
routinely run on dynamic IPs. Reproducing it exactly is not optional: a
conventional TLS client cannot connect to a real deployment.

```swift
// Trust the CA chain, then compare the certificate's common name.
let cortex = try await Cortex.open("ssl://root:secret@cortex.example.com:27492/?certdir=/path/to/certs")

// Pin the server instead. Chain trust is disabled entirely.
let pinned = try await Cortex.open("ssl://root:secret@10.0.0.5:27492/?certhash=df2449...")

// No password: authenticate with the client certificate Synapse names
// "{user}@{hostname}", found in the certificate directory.
let byCert = try await Cortex.open("ssl://root@cortex.example.com:27492/?certdir=/path/to/certs")
```

What it does, matching `synapse/lib/link.py`:

- **Hostname verification is off** in both modes.
- **`certhash` takes precedence.** When set, chain trust is disabled and the
  SHA-256 of the peer's DER certificate is compared to the pin; the common name is
  then not consulted at all, mirroring Synapse's `if certhash: ... elif hostname:`.
  A mismatch raises `TLSError.badCertificate` (Synapse's `LinkBadCert`).
- **Otherwise the CA chain is verified** and the certificate's subject **common
  name** — not its SAN — is compared to the hostname, exactly, with no wildcard
  handling and no case folding, because Synapse compares with `!=`. Being more
  permissive would accept certificates that a Python client rejects. A mismatch
  raises `TLSError.badCertificateHost` (`BadCertHost`).
- **A user with no password** authenticates by client certificate, resolved as
  `{user}@{hostname}` from the certificate directory, and the handshake's `auth`
  field stays nil.
- Synapse's certificate directory layout (`cas/`, `hosts/`, `users/`) is read
  directly, so existing deployments work without re-provisioning. The directory
  comes from the URL's `certdir`, else `Config.certificateDirectory`, else
  `$SYN_CERT_DIR`, else `~/.syn/certs`.

Two things worth knowing when standing up a server to test against: a listener
whose URL carries `?ca=` gets `CERT_REQUIRED`, so it *only* accepts clients
presenting a certificate — it cannot also serve password authentication. And the
session user is the certificate's common name, so a certificate issued to
`root@localhost` needs a cell user of that exact name.

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

**`callTimeout` bounds each wait, not each call.** `Config.callTimeout` is nil by
default, matching Synapse, which has no client-side deadline. When set, it bounds
a single wait for a server message. For a unary call that is the whole call, since
it is one wait. For a generator it bounds the gap *between* yields rather than the
total duration, because a legitimate Storm query can run for hours — it is a
liveness check, not a budget. Size it against the quietest query you expect, or
leave it nil and cancel the task instead — **task cancellation is honoured**, so
`withThrowingTaskGroup`, a parent task's cancellation, or a test's time limit all
unblock a call waiting on a server.

`Config.connectTimeout` covers establishing the TCP connection only, and
`Config.handshakeTimeout` (nil by default, like Synapse) covers the `tele:syn`
exchange. They are separate because a cold cell can take far longer to
authenticate and assemble its `sharinfo` than to accept a socket.

Writes are bounded by the same deadline, since a peer that accepts the connection
and stops reading fills the TCP window and would otherwise stall a call before it
ever waited for a reply.

A link that timed out or was cancelled is closed rather than returned to the pool.
The reply may still arrive, and a recycled link would hand another call's result
to the next caller.

**Abandoned generators close their link.** Synapse closes rather than draining,
and so does this client: reading an unbounded Storm result set to recycle a socket
costs far more than opening a new connection.

**Backpressure is real, not buffered.** Links disable `autoRead` and issue reads
only when a consumer is waiting, so a slow consumer applies backpressure to the
server instead of filling a userspace buffer.

## Not yet implemented

- **Synapse 3.x in the `Synapse` facade.** `Cortex` models 2.x and refuses any
  other major rather than mis-decoding its nodes. The `Telepath` layer is version
  agnostic and is verified against 3.0.0, so `Proxy` works there today. See
  [docs/synapse-3.0.md](docs/synapse-3.0.md).
- **`aha://` resolution** and **AHA mirror pools**. Specified in
  [spec.md](spec.md) §3.9 and scheduled as M7 and M8; not built yet.
- **`Proxy.state`.** A dropped main link surfaces as an error and the proxy never
  re-handshakes — deliberate, because a silent re-handshake loses server-side
  share state and would loop on `AuthDeny` after a credential rotation. The
  missing half is telling the caller it happened: `Proxy.state` as an
  `AsyncStream` is specified in [spec.md](spec.md) §8 and scheduled as M6, so a
  caller can reconnect on its own terms by opening a new `Proxy`.
- **Server side.** Out of scope.
