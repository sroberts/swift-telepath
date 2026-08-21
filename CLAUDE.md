# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

MVP built: codec, transport, handshake, unary calls, generators, connection pool, and a typed Cortex facade, all verified against a live Synapse 2.249.0 Cortex. `spec.md` remains the requirements source of truth — read it before implementing anything, and update it when a decision changes rather than letting code and spec diverge. README.md's "Not yet implemented" section is the current gap list (`aha://` and mirror pools, reconnect, server side).

## What this is

A SwiftNIO client for **Telepath**, the msgpack RPC protocol fronting Synapse services (Cortex, Axon, AHA, JsonStor). Protocol target `(3, 0)`, pinned to Synapse **2.249.0**. Swift 6 strict concurrency, macOS 14+ / iOS 17+ / Linux, Swift 6.2+ toolchain
(declared by the manifest's tools version, because dependencies require it).

Telepath has **no published specification** — it is defined by its Python implementation. Any protocol question is answered by reading upstream Synapse source (file references are listed in `spec.md` §9), never by inference. Conformance vectors generated from Python are the de facto spec.

## Commands

```bash
swift build
swift test                                   # unit tests; integration suites skip themselves
SWIFTNIO_STRICT=1 swift test                 # what CI runs: event-loop-after-shutdown crashes
swift package generate-documentation --target Telepath   # DocC; CI fails on warnings
swift test --filter VectorTests              # one suite
swift test --filter DecoderTests.overflow    # one test
```

Integration tests are gated on `TELEPATH_TEST_URL` and skip when it is unset. A local Cortex is faster and more informative than Docker — the pinned Synapse is already installed in `.venv-synapse` (uv):

```bash
./scripts/setup-test-env.sh                  # one-time
./scripts/run-test-cortex.sh &               # 127.0.0.1:27492 + cell socket
TELEPATH_TEST_URL="tcp://root:s3cret@127.0.0.1:27492/" swift test
```

Regenerate codec vectors after a Synapse bump:

```bash
.venv-synapse/bin/python tools/genvectors.py > Tests/MsgpackTests/vectors.json
```

Fuzz the codec (failures print the seed to replay):

```bash
swift run -c release msgpack-fuzz --seconds 60
swift run -c release msgpack-fuzz --seed 42 --iterations 1000
```

Record a real exchange for the replay corpus — run the proxy, point the client at
it, then stop the proxy:

```bash
.venv-synapse/bin/python tools/capture.py --listen 27493 --upstream 127.0.0.1:27492 \
    --out Tests/TelepathTests/protocol-vectors.json --label <scenario>
```

Note: Synapse refuses to start a cell when the disk is near full; `scripts/run-test-cortex.sh` disables that guard, including for the nested axon/jsonstor cells, which read `cell.yaml` rather than the environment.

## Target layout and dependency direction

```
Sources/Msgpack/    # value model, packer, unpacker, streaming unpacker, Codable decoder
                    # NO package dependencies and no Foundation — must stay extractable
Sources/Telepath/   # TelepathURL, Link (NIO), Proxy (actor: handshake + pool + calls),
                    # TelepathStream, Share, errors, retn decoding → Msgpack, NIO, Logging
Sources/TelepathTLS/  # cert directory, pinning, CN check      → NIOSSL, Crypto, X509
Sources/Synapse/    # Cortex facade, Storm message model, Node   → Telepath
Sources/TelepathTestKit/  # scriptable daemon, integration gating
```

Allowed dependencies: `swift-nio`, `swift-nio-ssl`, `swift-log`, `swift-crypto`, `swift-certificates` (X509, for common-name extraction). Nothing else. Never expose `EventLoopFuture` in public API — bridge at the boundary. `Proxy` is an actor; all public value types are `Sendable`.

`Msgpack` deliberately avoids Foundation, so use the local `hexEncode` and `isStrictUTF8` helpers rather than reaching for `String(format:)` or `String(bytes:encoding:)`. `String(validating:as:)` is macOS 15+ and unavailable at this deployment target.

## Protocol invariants that span files

These are the things that break silently if violated. They are cross-cutting, so they cannot be inferred from any single source file.

**The msgpack is Python-flavored, not standard.** Two deviations, both mandatory:
- Ext type 0 = unsigned big-endian integer > `2^64-1`; ext type 1 = signed big-endian < `-2^63`. Model these as `MsgpackValue.bigInt`, kept distinct from `.ext` so an unknown ext code is a clean protocol error rather than a decode crash. Any ext code other than 0/1 is a protocol error.
- Strings are encoded with `unicode_errors='surrogatepass'`, so a msgpack `str` may hold UTF-8-encoded lone surrogates that Swift `String` cannot represent. Decode to `.string` when valid UTF-8, `.rawString([UInt8])` otherwise, and round-trip raw bytes exactly. This is not defensive — production Cortex data contains such strings, and failing the message would make the library unusable.
- `strict_map_key=False`: map keys are arbitrary `MsgpackValue`, not `String`. `use_bin_type=True`: `str` and `bin` are never conflated.

**No framing.** The link is a continuous msgpack stream fed to a streaming unpacker. Do not look for a length prefix. Every message is a 2-element array `(name, infoMap)`.

**Link-per-call ownership.** A pool link is exclusively owned by one call from `t2:init` until its terminator (`t2:fini`, `t2:yield` with `retn: None`, error, or `t2:share`). Return it to the pool only on clean termination. If a consumer abandons a generator early, **close the link** — never drain it to recycle the socket.

**Pool links skip the handshake.** They connect and send `t2:init` carrying the session iden obtained on the main link. The `sess` value is the only thing binding a pool link to an authenticated session, which is why handshake `sess` absence (pre-2.166 server, task v1) must fail loudly rather than degrade.

**Share teardown goes on the main link.** `share:fini` is sent on the handshake link, not a pool link — `ShareTests.teardownUsesMainLink` asserts the connection identity, not just the message. A share's *call* link is released as soon as the `t2:share` reply lands, unlike a generator's. The main link now has a permanent reader: unknown message names there are logged and dropped, never fatal, because the link disables `autoRead` and an unread main link would eventually stall a server that wrote to it.

**Errors are `retn` tuples, not exceptions.** `(True, value)` or `(False, (excName, infoMap))` everywhere. Map to a single `TelepathRemoteError` carrying the name string plus decoded info; never mirror Synapse's exception hierarchy, and never fail decoding because a name is unrecognized (`.other(String)` case is required).

**TLS deviates from the norm deliberately, and the deviations are load-bearing.** Hostname verification is off. `certhash` takes precedence and, when present, disables chain trust and skips the name check entirely (Synapse: `if certhash: ... elif hostname:`). Otherwise the CA chain is verified and the subject **common name** is compared exactly — no wildcards, no case folding — because Synapse compares with `!=` and being more permissive would accept certificates a Python client rejects. A user with no password authenticates by a client certificate named `{user}@{hostname}`.

SNI is sent (Synapse passes asyncio's `server_hostname`) for hostnames but never for IP literals, which SNI forbids and NIOSSL rejects.

Three NIOSSL traps, all found by testing rather than review: setting `certificateVerification = .none` means the custom verification callback is **never invoked**, silently disabling pinning — verification must stay enabled and the callback overrides BoringSSL's logic anyway. The link disables `autoRead`, so a TLS handshake stalls unless a read is kicked off explicitly, since NIOSSL only re-reads when a read is already pending. And a channel that never goes active never fires `channelInactive`, so a handshake promise created before `connect` is abandoned when the connection is refused — NIO traps on a leaked promise, so that crashed the process rather than throwing. Always complete that promise on every error path.

**Forward compatibility is required, not optional.** Unknown Storm message kinds decode to `.other(name:data:)`; unknown `features` entries are gated with `hasFeature(_:minVersion:)`. Vertex adds both between minor releases.

## Explicit non-goals

Do not implement these without the spec being changed first: server side / `Daemon`, task v1 (`task:init`/`task:fini` — detect and error), `aha://` resolution, `getPipeline`, mirror pools / `dynmirror` / spawned links / fd passing, Network.framework transport, and Python-parity dynamic member lookup (`@dynamicCallable` cannot express async throwing calls with keyword args).

## Testing structure

Four layers, each answering a question the others cannot:

- **`VectorTests` / `LargePayloadTests`** — bytes generated by the real Synapse packer. The codec's contract.
- **`PropertyTests` + `msgpack-fuzz`** — seeded generative checks; the executable is the long-running version of the same code (`MsgpackFuzzCore`).
- **`FakeDaemonTests`** — a scriptable server (`TelepathTestKit`) for everything a healthy Cortex will not do: refused handshakes, wrong version, missing session iden, death mid-generator, malformed framing.
- **`ReplayTests`** — bytes captured from a live server by `tools/capture.py`. Tests parsing against production traffic rather than against assumptions.
- **`IntegrationTests` / `CortexTests`** — a live Cortex, gated on `TELEPATH_TEST_URL`.

Integration suites skip when no server is configured. **CI must set `TELEPATH_REQUIRE_INTEGRATION=1`**, which turns a missing server into a failure — without it a CI job reports green having exercised no protocol code at all.

## Decisions already made (do not silently reverse)

- **Non-UTF-8 strings repair by default.** `MsgpackDecoder` substitutes U+FFFD for a `.rawString` reaching a `String`; `.throw` is opt-in. Raw bytes stay reachable via `MsgpackValue.stringBytes`. Settles spec §8's first open question.
- **Maps do not round-trip byte-exactly.** Swift `Dictionary` is unordered, so re-encoding permutes map keys. Held to semantic equality plus identical encoded length in `VectorTests`. Everything else is byte-exact; do not "fix" a failing map round-trip by weakening the non-map assertions.
- **A dropped link surfaces as an error**; `Proxy` does not re-handshake. Re-handshaking loses server-side share state and loops after a credential rotation.
- **Abandoned generators close their link** rather than draining.
- **Cancellation must be honoured on every await that waits on the network.** `Link.receive` wraps its continuation in `withTaskCancellationHandler`; a bare `withCheckedThrowingContinuation` ignores cancellation and leaves the call suspended until the server replies. That also breaks everything built on cancellation, including swift-testing's `.timeLimit` — the regression test for it hung past its own limit. A cancelled call closes its link for the same reason a timed-out one does.
- **`callTimeout` bounds one wait, not one call.** Nil by default. For a generator that means the gap between yields, not total duration — a Storm query may legitimately run for hours. A timed-out link is **closed, never pooled**: the late reply would otherwise be delivered to the next call on that link. `CallTimeoutTests.lateReplyDoesNotDesync` covers exactly that, and fails if the link is released instead of closed.
- **Nothing may touch an event loop group after it is shut down.** `Proxy.close()` cancels *and awaits* the cull loop, the main-link reader, and every in-flight pool top-up before `shutdownGracefully`; `FakeDaemon.stop()` drains its per-connection handler chains the same way. A background top-up sitting inside `Link.connect`, or a scripted reply sleeping before it writes, is holding the group — cancelling alone does not get it off. SwiftNIO logs this to stderr and passes the test; `SWIFTNIO_STRICT=1` turns it into a crash, which is why CI sets it. Await from inside the actor is safe: the actor is released at every suspension.
- **Integers compare numerically across cases.** msgpack draws no wire distinction between signed and unsigned, so `.int(0)` decodes as `.uint(0)`; `MsgpackValue`'s `Equatable`/`Hashable` are hand-written so equal numbers compare and hash equally, `.bigInt` included. Found by fuzzing. Do not revert to a derived conformance.

Pool prefill is deliberately **reactive**: links top up toward `poolLowWater` only after one has been taken, so a proxy that is never called opens no spare connections. Eager filling would be wrong for a client on a metered link.

Still open from spec §8: `Proxy.state` as an `AsyncStream`, and per-platform pool water marks (the Python 4/12 defaults are likely wrong for iOS on cellular, and `Config` already makes them configurable).

## Conventions

- Default port is **27492**. `unix://` and `cell://` put the share name after a **colon** inside the path, not after a slash; share defaults to `*`.
- Pool water marks (low 4 / high 12, 10s cull) mirror Python and must stay configurable — they are likely wrong for iOS on cellular. Low-water top-up is implemented but reactive; see the note above.
- Bump the pinned Synapse version in one place and regenerate vectors; version drift is caught by a scheduled job, not by review.
