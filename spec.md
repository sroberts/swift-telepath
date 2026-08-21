# swift-telepath: Specification for a Swift Telepath Client

**Version:** 0.1 (draft)
**Protocol target:** Telepath `(3, 0)`, derived from Synapse `2.249.0`
**Date:** 2026-08-17

---

## 1. Bottom Line

Build `swift-telepath`, a SwiftNIO-based client for Telepath, the msgpack RPC protocol that fronts every Synapse service (Cortex, Axon, AHA, JsonStor). The protocol is small: an unframed msgpack stream, a four-field handshake, and five message types for calls, generators, and shared objects. Three things make this non-trivial and drive most of the design:

1. **Python-flavored msgpack.** Synapse packs integers wider than 64 bits as msgpack ext types 0 and 1, and encodes strings with `unicode_errors='surrogatepass'`, producing byte sequences that Swift's `String` cannot represent. No off-the-shelf Swift msgpack package handles either case. Write the codec.
2. **No published protocol spec.** Telepath is defined by its implementation. Pin the library to a Synapse version, generate conformance vectors from Python, and re-run them on every Synapse minor release.
3. **Link-per-call concurrency.** Telepath v2 dedicates a TCP connection to each in-flight call for its entire duration, including streaming generators. The client owns a connection pool and returns links only after a call terminates cleanly.

Ship in five milestones: codec, transport plus handshake, unary calls, generators and shares, Cortex convenience layer. Target Swift 6 strict concurrency, macOS 14+ / iOS 17+ / Linux.

---

## 2. Scope

### 2.1 In scope (v1.0)

- Client side of the Telepath protocol, version `(3, 0)`, task v2 only
- Transports: `tcp://`, `ssl://`, `unix://`, `cell://`
- Password authentication and TLS client certificate authentication
- Certificate pinning by SHA-256 fingerprint (`certhash`)
- Unary calls, async generator calls, dynamically shared objects
- Connection pooling with the same water marks Synapse uses
- A typed Cortex facade: Storm execution, `callStorm`, cell info, user and auth APIs
- A msgpack value model plus `Codable` bridging

### 2.2 Out of scope (v1.0, revisit later)

- **Server side.** No `Daemon` equivalent. Serving Telepath from Swift is a separate project.
- **Task v1** (`task:init` / `task:fini`). Synapse deprecated it in 2.166.0 and it only triggers when the server omits a session iden. Detect it, raise a clear error, do not implement it.
- **`Pipeline`** (`getPipeline`). Deprecated in Synapse 2.167.0.
- **Spawned links and fd passing.**

`aha://` resolution and mirror pools were out of scope for v1.0 and are now
specified for v1.1; see §3.9 and M7-M8. `dynmirror` remains unimplemented but is no
longer a non-goal — it is the server-side feature AHA pools are built on, and §3.9
records what a client must do about it.

### 2.3 Non-goals

Do not attempt Python API parity through Swift dynamic member lookup. Swift's `@dynamicCallable` cannot express async throwing calls with keyword arguments cleanly. Expose an explicit call API and layer generated typed facades on top.

---

## 3. Protocol Reference

Everything below is verified against Synapse `2.249.0`. File references point at the upstream repository.

### 3.1 Wire format

Source: `synapse/lib/link.py`, `synapse/lib/msgpack.py`

- **Framing:** none. The link is a continuous msgpack stream. A reader feeds bytes to a streaming unpacker and dispatches each complete object. Do not look for a length prefix.
- **Message shape:** every message is a two-element array `(name: String, info: Map)`. The name selects the handler; the map carries the payload.
- **Read chunk:** Synapse reads up to 16 MiB per socket read. Writes chunk at 64 MiB. Neither is protocol-significant, but sizing NIO's `ByteBuffer` and max-frame limits in the same range avoids surprises on large Storm result sets.
- **No compression, no keepalive frames, no heartbeat.** Liveness comes from TCP.

**Packer settings Synapse uses:**

| Setting | Value | Consequence for the Swift codec |
|---|---|---|
| `use_bin_type` | `True` | Emit `str8/16/32` for text, `bin8/16/32` for bytes. Never conflate them. |
| `unicode_errors` | `surrogatepass` | Strings may contain UTF-8-encoded lone surrogates (`ED A0 80` through `ED BF BF`). Swift `String` rejects these. |
| `default` hook | `_ext_en` | `int > 0xFFFFFFFFFFFFFFFF` becomes `ExtType(0, bigEndianUnsignedBytes)`. `int < -0x8000000000000000` becomes `ExtType(1, bigEndianSignedBytes)`. |

**Unpacker settings:**

| Setting | Value | Consequence |
|---|---|---|
| `raw` | `False` | Decode `str` as text, `bin` as bytes. |
| `use_list` | `False` | Arrays arrive as tuples. Irrelevant to Swift, relevant when generating vectors. |
| `strict_map_key` | `False` | **Map keys are not guaranteed to be strings.** The value model must allow arbitrary keys. |
| `ext_hook` | `_ext_un` | Ext 0 decodes as unsigned big-endian integer, ext 1 as signed big-endian. Any other ext code is a protocol error. |
| `max_buffer_size` | `2^32 - 1` | Upper bound for a single message. |

### 3.2 Connect and handshake

Source: `synapse/telepath.py::Proxy.handshake`, `synapse/daemon.py::Daemon._onTeleSyn`

Client sends:

```
('tele:syn', {
    'auth': (username, {'passwd': password}) | None,
    'vers': (3, 0),
    'name': shareName,        # '*' when the URL path is empty
})
```

Server replies with a single `tele:syn`:

```
('tele:syn', {
    'vers':     (3, 0),
    'retn':     (True, None) | (False, (errName, errInfo)),
    'sess':     '<32-char hex guid>',
    'sharinfo': {'meths': {...}, 'syn:version': (2,249,0), 'syn:commit': '...', 'classes': [...]},
    'features': {'tellready': 1, 'dynmirror': 1, 'tasks': 1, 'issuewait': 1, 'shutdowndrain': 1},
    'ahainfo':  {...},        # present only when the service registered with AHA
})
```

Client behavior:

1. Compare major versions only. `vers[0] != 3` is fatal (`BadMesgVers`).
2. Unpack `retn`. A `(False, ...)` retn carries the authentication or lookup failure. Raise it.
3. Store `sess`. Its presence selects task v2. Its absence means the peer is pre-2.166 and the client must fail with an unsupported-server error.
4. Store `sharinfo['meths']`. Each entry is `{name: {}}` or `{name: {'genr': true}}`. The `genr` flag tells the client that the method returns a generator, which determines whether the caller gets a value or an `AsyncSequence`. This is the only method-shape metadata the protocol provides.
5. Store `features`. Gate optional behavior on `features[name] >= requiredVersion`.

**Share naming:** `name` may contain slashes. The daemon splits on the first `/`, resolves the leading segment as the shared object, and passes the remainder as a path to `getTeleApi`. `tcp://host:27492/cortex/foo/bar` resolves object `cortex` with path `('foo','bar')`.

### 3.3 Task v2 exchange

Source: `synapse/telepath.py::Proxy.taskv2`, `synapse/daemon.py::t2call`

Client takes a link from the pool and sends:

```
('t2:init', {
    'todo': (methName, argsArray, kwargsMap),
    'name': shareIden | None,     # None targets the session's root object
    'sess': sessionIden,
})
```

The server replies with exactly one of three openings:

**Unary result**
```
('t2:fini', {'retn': (True, value)})          # or (False, (errName, errInfo))
```
Return the link to the pool.

**Generator**
```
('t2:genr', {})
('t2:yield', {'retn': (True, item)})    ...repeated...
('t2:yield', {'retn': None})            # normal end of stream
```
An exception mid-stream arrives as `('t2:yield', {'retn': (False, errInfo)})` and terminates the stream. Return the link to the pool on either terminator. Any message other than `t2:yield` after `t2:genr` is a protocol violation: fail the stream and close the link.

**Dynamic share**
```
('t2:share', {'iden': shareIden, 'sharinfo': {...}})
```
Return the link to the pool immediately. The share is addressed by passing `iden` as `name` on subsequent `t2:init` messages. Tear it down by sending `('share:fini', {'share': iden})` on the **main** link, not a pool link.

**Critical invariant:** a pool link is exclusively owned by one call from `t2:init` until its terminator. If the consumer abandons a generator early, Synapse closes the link rather than trying to drain it. Do the same. Draining an unbounded Storm query to recycle a socket is worse than opening a new one.

### 3.4 Main link messages

The link created at handshake stays open and carries out-of-band traffic for shares created under task v1 plus share teardown:

- `('share:data', {'share': iden, 'data': (True, item) | None})`, inbound
- `('share:fini', {'share': iden, 'isexc': bool})`, both directions

v1 clients only need to send `share:fini` and tolerate inbound messages they do not recognize. Log and drop unknown message names on the main link. Do not close the connection.

### 3.5 Error model

Source: `synapse/common.py::err`, `synapse/common.py::result`

Every result is a `retn` tuple: `(True, value)` or `(False, (excName, info))`.

`info` carries, when a traceback existed: `efile`, `eline`, `esrc`, `ename`. For `SynErr` subclasses it also carries the exception's own items, most importantly `mesg`. For non-`SynErr` exceptions it carries `mesg` as the stringified exception.

Python reconstructs the class by name from `synapse.exc`. Swift cannot and should not mirror hundreds of exception classes. Model it as:

```swift
public struct TelepathRemoteError: Error, Sendable {
    public let name: String                     // e.g. "AuthDeny", "NoSuchMeth", "BadSyntax"
    public let mesg: String?
    public let info: [String: MsgpackValue]     // full decoded info map
}
```

Provide a `TelepathErrorName` enum with the two dozen names clients actually branch on (`AuthDeny`, `NoSuchName`, `NoSuchMeth`, `NoSuchObj`, `BadMesgVers`, `BadMesgFormat`, `BadSyntax`, `BadTypeValu`, `IsFini`, `LinkShutDown`, `LinkBadCert`, `BadCertHost`, `SchemaViolation`, `TimeOut`), plus an `.other(String)` case. Never fail decoding because a name is unrecognized.

### 3.6 URL schemes

Source: `synapse/telepath.py::openinfo`

| Scheme | Form | Notes |
|---|---|---|
| `tcp` | `tcp://user:pass@host:27492/share` | Default port **27492**. Share name is the path minus the leading slash. |
| `ssl` | `ssl://user@host:27492/share?certname=...&certhash=...&hostname=...` | See TLS below. |
| `unix` | `unix:///path/to/sock:share` | Share name follows a colon inside the path. Defaults to `*`. |
| `cell` | `cell:///path/to/celldir:share` | Appends `sock` to the cell directory and connects over unix. |
| `aha` | `aha://service` or `aha://service...` | Specified in §3.9, targeted at M7. Resolves through the AHA registry set, merges its `urlinfo` by §3.9's precedence, then recurses. A trailing `...` is a relative name the registry completes with its own network. |
| `*+consul` | any | Removed upstream. Reject. |

Query parameters carry `certdir`, `certname`, `certhash`, `hostname`, and `name`. Parse them; do not silently ignore unknown ones, warn instead.

### 3.7 TLS behavior

Source: `synapse/telepath.py::openinfo`, `synapse/lib/link.py::Link.__anit__`

Synapse deliberately does not use standard hostname verification, because Synapse services routinely run on dynamic IPs. Reproduce this exactly or connections will fail against real deployments:

1. `check_hostname` is **off** in the SSL context.
2. If `certhash` is set: trust is disabled entirely (`CERT_NONE`) and the client compares the SHA-256 fingerprint of the peer's DER certificate to the pinned value. Mismatch raises `LinkBadCert`.
3. Otherwise: the client verifies against the CA chain in the Synapse cert directory and then compares the certificate's **subject Common Name** against the expected hostname. Mismatch raises `BadCertHost`. Note this checks CN, not SAN.
4. Client certificates: when the URL supplies a user with no password, Synapse auto-resolves a client cert named `{user}@{hostname}` from the cert directory. The daemon then authenticates the session from the certificate rather than a password, and `auth` in the handshake stays `None`.

In Swift, implement all of this through `NIOSSLContext` with `certificateVerification: .none` plus a custom verification callback, or `.fullVerification` with `NIOSSLCustomVerificationCallback` doing the CN comparison. Do not use `URLSession`, it cannot express this.

Support reading a Synapse cert directory layout (`certs/cas/*.crt`, `certs/users/*.crt`, `certs/users/*.key`) so existing deployments work without re-provisioning.

### 3.8 Connection pool parameters

Source: `synapse/telepath.py::Proxy`

- Low water mark: 4 idle links. Below it, the client opens replacements in the background.
- High water mark: 12 idle links.
- Cull interval: 10 seconds, closing at most one link per proxy per interval while above the high water mark.

Pool links skip the handshake. They connect and go straight to `t2:init` carrying the session iden obtained on the main link. This is why the session iden matters: it is the only thing binding a pool link to an authenticated session.


### 3.9 `aha://` resolution and mirror pools

Telepath has no published specification, so this section is a reading of
`synapse/telepath.py` and `synapse/lib/aha.py` at 2.249.0, not a design.

**Registry set.** An `aha://` URL resolves against a *set* of registry URLs, not
one. Python holds them in a module-global refcounted dict (`aha_clients`), loaded
from `telepath.yaml`'s `aha:servers` / `aha:registry`. A global is wrong for a
library; `Config` carries the registry list instead, and a `Proxy` opened from an
`aha://` URL with an empty registry list fails with a clear error rather than
hanging. Python raises `NotReady: No aha servers registered to lookup {host}`.

**Resolution.** For each registry in turn:

1. Open a Telepath connection to the registry and call `getCellInfo()`.
2. Call `getAhaSvc(name, filters={'mirror': bool})`. The `filters` argument is
   sent **only** when the registry's own Synapse is >= 2.95.0; `mirror` comes
   from the URL's `?mirror=` query parameter parsed as YAML-ish truth.
3. A `None` result, or `svcinfo['online']` falsy, means try the next registry.
4. Otherwise merge and recurse.

Every registry failing raises the **last** exception seen, or `NoSuchName` if none
threw. Falling through the whole set without an online service is not success.

**Name resolution.** A service name ending in `...` is relative: the registry
substitutes its own `aha:network`, so `cortex...` becomes `cortex.<network>`
(`aha.py:_getAhaName`). Absolute names pass through. This happens server-side —
the client sends the name as written.

**Merge rules** (`mergeAhaInfo`), and the order matters:

| Field | Winner |
|---|---|
| `path` | local — the AHA-provided path is discarded outright |
| `user` | local, but only if the local URL specified one |
| everything else | upstream |

The merged `urlinfo` is then fed back through the normal open path, so an AHA
service that resolves to `ssl://` gets §3.7's TLS rules unchanged. Resolution
recurses; a resolved URL is an ordinary URL.

**Pools.** If the resolved `svcinfo` carries a `services` key, the name is a pool
rather than a service, and the client enters pool mode instead of connecting:

- Call the generator `iterPoolTopo(poolname)` on the **registry** proxy. It first
  replays the pool's current membership, then stays open and streams changes.
- Messages are `('svc:add', svcinfo)` and `('svc:del', {name})`. An unrecognised
  message kind is logged and dropped, per the forward-compatibility rule that
  already governs Storm messages and main-link traffic.
- Each member becomes its own `aha://<svcname>` connection. `svc:add` for a name
  already present replaces the existing connection.
- Calls round-robin over the ready members (Python uses a deque and refills it
  from the live set when it empties).
- If the topology stream drops, the **whole pool resets** — every member
  connection is torn down and membership is rebuilt from a fresh
  `iterPoolTopo`. Python retries on a 1s delay, indefinitely.

The pool's `AsyncStream` of topology messages is exactly the kind of long-lived
generator §3.3's link-per-call rule governs, so the topology stream owns its link
for its whole life and never returns it to the pool.

**What this does not include.** `dynmirror` is a server-side capability advertised
in `features`; a client that does not ask for it is not broken by its absence.
Spawned links and fd passing stay out of scope.
---

## 4. Package Architecture

```
swift-telepath/
├── Sources/
│   ├── Msgpack/            # standalone, no Telepath dependency
│   ├── Telepath/           # links, pool, proxy, shares, errors
│   ├── TelepathTLS/        # cert directory, pinning, CN verification
│   ├── Synapse/            # Cortex/Axon/AHA typed facades, Storm types
│   └── TelepathTestKit/    # vector loading, fake daemon, docker helpers
└── Tests/
```

**Dependencies:** `swift-nio`, `swift-nio-ssl`, `swift-log`, `swift-crypto` (SHA-256 for pinning on Linux). Nothing else. Keep `Msgpack` dependency-free so it is extractable.

**Platforms:** macOS 14+, iOS 17+, Linux (Ubuntu 22.04+). Use SwiftNIO rather than Network.framework so Linux tooling and CI work. Do not add a Network.framework transport in v1.

**Concurrency:** Swift 6 language mode, strict concurrency checking. `Proxy` and `LinkPool` are actors. All public value types are `Sendable`. Never expose an `EventLoopFuture` in the public API; bridge at the boundary.

---

## 5. API Design

### 5.1 Value model

```swift
public enum MsgpackValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case bigInt(sign: FloatingPointSign, magnitude: [UInt8])  // ext 0 / ext 1
    case double(Double)
    case string(String)
    case rawString([UInt8])        // valid msgpack str, invalid Swift String
    case binary([UInt8])
    case array([MsgpackValue])
    case map([MsgpackValue: MsgpackValue])
    case ext(code: Int8, data: [UInt8])
}
```

Three decisions worth defending:

- **`rawString` is mandatory, not defensive.** Synapse stores strings that survived `surrogatepass` encoding, which appear in real Cortex data (malformed filenames, decoded network captures, scraped content). Failing the whole message because one property contains a lone surrogate would make the library unusable against production data. Decode to `.string` when the bytes are valid UTF-8, `.rawString` otherwise. Round-trip `.rawString` byte-for-byte.
- **`bigInt` is separate from `int`/`uint`.** Ext 0 and ext 1 are the only ext codes the protocol defines, and both mean "integer too wide for 64 bits". Keep them distinct from `.ext` so encoding is unambiguous, and keep `.ext` so an unknown code produces a clean protocol error rather than a decode crash.
- **Map keys are `MsgpackValue`, not `String`.** `strict_map_key=False` permits integer and tuple keys, and Synapse uses them (layer index structures, node data). Provide `subscript(_ key: String) -> MsgpackValue?` as sugar.

### 5.2 Codable bridge

Ship `MsgpackEncoder` and `MsgpackDecoder` implementing the standard `Encoder`/`Decoder` protocols over `MsgpackValue`. This is what makes the typed Synapse layer worth using:

```swift
let info: CellInfo = try await proxy.call("getCellInfo", returning: CellInfo.self)
```

Decoding a `.rawString` into a `String` property throws `MsgpackError.invalidUTF8(path:)` with the coding path. Callers who need those bytes take `[UInt8]` or `MsgpackValue` in that position.

### 5.3 Connecting

```swift
public struct TelepathURL: Sendable {
    public init(_ string: String) throws
    // scheme, host, port, user, passwd, path/share, certname, certhash, hostname, certdir
}

public actor Proxy {
    public static func open(_ url: String, config: Config = .init()) async throws -> Proxy
    public static func open(_ url: TelepathURL, config: Config = .init()) async throws -> Proxy

    public var sessionIden: String { get }
    public var serverVersion: (Int, Int, Int)? { get }   // sharinfo['syn:version']
    public var features: [String: Int] { get }
    public var methods: [String: MethodInfo] { get }     // sharinfo['meths']

    public func hasFeature(_ name: String, minVersion: Int = 1) -> Bool
    public func close() async
}

public struct Config: Sendable {
    public var connectTimeout: Duration = .seconds(10)
    public var callTimeout: Duration? = nil          // nil means no client-side deadline
    public var poolLowWater: Int = 4
    public var poolHighWater: Int = 12
    public var poolCullInterval: Duration = .seconds(10)
    public var certDirectory: URL? = nil
    public var logger: Logger = Logger(label: "telepath")
}
```

### 5.4 Calling

```swift
extension Proxy {
    // Unary. Throws TelepathRemoteError on (False, ...) retn.
    public func call(_ method: String,
                     _ args: [MsgpackValue] = [],
                     kwargs: [String: MsgpackValue] = [:],
                     share: String? = nil) async throws -> MsgpackValue

    public func call<T: Decodable>(_ method: String,
                                   _ args: [MsgpackValue] = [],
                                   kwargs: [String: MsgpackValue] = [:],
                                   share: String? = nil,
                                   returning: T.Type) async throws -> T

    // Generator. The call is issued on first iteration, matching Synapse's GenrIter.
    public func stream(_ method: String,
                       _ args: [MsgpackValue] = [],
                       kwargs: [String: MsgpackValue] = [:],
                       share: String? = nil) -> TelepathStream

    // Dynamic share.
    public func callForShare(_ method: String, ...) async throws -> Share
}

public struct TelepathStream: AsyncSequence, Sendable {
    public typealias Element = MsgpackValue
    public func decode<T: Decodable>(_ type: T.Type) -> AsyncThrowingMapSequence<...>
    public func collect() async throws -> [MsgpackValue]
}

public actor Share {
    public var iden: String { get }
    public var methods: [String: MethodInfo] { get }
    public func call(...) async throws -> MsgpackValue
    public func stream(...) -> TelepathStream
    public func close() async                 // sends share:fini
}
```

`Share` sends `share:fini` on `deinit` as a backstop, but document explicit `close()` as the contract. Swift actors give no deterministic deinit ordering.

### 5.5 Storm and the Cortex facade

The Cortex API is where callers spend their time, so type it properly.

Source: `synapse/lib/view.py`, which emits the Storm stream.

```swift
public enum StormMessage: Sendable {
    case initialized(StormInit)          // ('init', {tick, abstick, text, hash, task, ...})
    case node(Node)                      // ('node', pode)
    case nodeEdits(NodeEdits)            // ('node:edits', ...)
    case print(String)                   // ('print', {mesg})
    case warn(StormWarn)                 // ('warn', {mesg, ...})
    case err(TelepathRemoteError)        // ('err', (name, info))
    case finished(StormFini)             // ('fini', {tock, abstock, took, count})
    case fire(name: String, data: MsgpackValue)   // ('storm:fire', ...)
    case other(name: String, data: MsgpackValue)  // forward-compatible
}

public struct Node: Sendable, Decodable {
    public let form: String
    public let value: MsgpackValue                       // ndef = (form, valu)
    public let iden: String
    public let tags: [String: MsgpackValue]
    public let props: [String: MsgpackValue]
    public let tagprops: [String: [String: MsgpackValue]]
    public let nodedata: [String: MsgpackValue]
    public let path: [String: MsgpackValue]
}

public struct Cortex: Sendable {
    public init(_ proxy: Proxy)
    public func storm(_ text: String, opts: StormOpts = .init()) -> AsyncThrowingStream<StormMessage, Error>
    public func nodes(_ text: String, opts: StormOpts = .init()) -> AsyncThrowingStream<Node, Error>
    public func callStorm<T: Decodable>(_ text: String, opts: StormOpts = .init(), returning: T.Type) async throws -> T
    public func count(_ text: String, opts: StormOpts = .init()) async throws -> Int
    public func getCellInfo() async throws -> CellInfo
    public func reqValidStorm(_ text: String) async throws
}
```

`.other` is not optional. Vertex adds Storm message kinds between releases, and a client that throws on an unknown kind breaks on upgrade.

`nodes(_:)` filters the stream to `.node` and rethrows `.err` as a Swift error. That is the 80 percent call path.

---

## 6. Conformance Testing

The protocol has no specification document, so the test suite is the specification.

### 6.1 Codec vectors

Write a Python generator script (`tools/genvectors.py`) that imports `synapse.lib.msgpack` and emits a JSON manifest of `{description, pythonRepr, hexBytes}` covering:

- All integer boundaries: `-2^63`, `-2^63 - 1` (ext 1), `2^64 - 1`, `2^64` (ext 0), plus a 40-byte magnitude
- `str` versus `bytes` under `use_bin_type`
- Lone surrogates through `surrogatepass`: `'\ud800'`, `'a\udfffb'`
- Non-string map keys: integers, nested tuples
- Empty containers, nested containers 8 levels deep
- Floats including NaN, infinities, negative zero
- A 20 MiB binary blob (exercises chunked reads)

Run both directions: decode the hex and compare to an expected `MsgpackValue`, then re-encode and compare bytes exactly. Byte-exact re-encoding matters because Telepath does no canonicalization and mismatches will not surface until a server rejects a message.

### 6.2 Protocol vectors

Capture real exchanges. Run a Synapse Cortex with a socat or eBPF tap, record the msgpack stream for: handshake success, handshake auth failure, unary call, unary exception, Storm query with 1000 nodes, early generator abandonment, `t2:share` from `getLayer`, share teardown. Replay them against the client with a scripted fake daemon in `TelepathTestKit`.

### 6.3 Integration tests

Run `vertexproject/synapse-cortex` in Docker in CI. Cover the matrix of transport (unix, tcp, ssl with pinning, ssl with client cert) against operation (unary, generator, share, concurrent calls exceeding the pool high water mark, server restart mid-generator). Gate merges on it.

### 6.4 Version drift

Pin the tested Synapse version in `Package.swift` metadata and in the README. Add a scheduled weekly CI job that pulls the latest Synapse release, regenerates codec vectors, and opens an issue on any diff. Telepath's major version has been 3 for years, but `features` entries and `sharinfo` contents change per release.

---

## 7. Milestones

| # | Deliverable | Exit criteria |
|---|---|---|
| M0 | `Msgpack` target | All codec vectors pass both directions. Fuzz target runs 1 hour clean. |
| M1 | Link, TLS, handshake | `Proxy.open` succeeds against a Docker Cortex over unix, tcp, ssl-pinned, and ssl-clientcert. `getCellInfo` returns typed. |
| M2 | Unary calls plus pool | Concurrent calls exceeding the high water mark behave. Remote exceptions map to `TelepathRemoteError`. Pool culls on schedule. |
| M3 | Generators and shares | Storm streams 100k nodes without unbounded memory growth. Early abandonment closes the link and leaks nothing. `t2:share` round-trips. |
| M4 | `Synapse` facade | `Cortex.nodes`, `callStorm`, `count` typed and documented. Node model decodes every form in the base Synapse model. |
| M5 | Hardening and docs | DocC published. Backpressure verified. Reconnect policy documented. 1.0 tagged. |
| M6 | `Proxy.state` | `state` reports `disconnected` when the main link drops, whether the server closed it cleanly or died. A timed-out or cancelled call does **not** report it — that closes one pool link and leaves the session intact. Dropping the stream leaks neither the proxy nor its event loop group. A caller-driven reconnect works end to end against a restarted server. |
| M7 | `aha://` resolution | Resolves a single service against a live AHA registry, merges `urlinfo` by §3.9's precedence, and recurses into `ssl://` with §3.7's rules intact. An empty registry list, an offline service, and an unreachable registry each fail with distinct, clear errors. |
| M8 | AHA mirror pools | A pool URL enters pool mode, replays membership, and round-robins calls. `svc:add` and `svc:del` are honoured live. A dropped topology stream resets and rebuilds the pool. Unknown topology messages are dropped, not fatal. |

M6 is independent of M7 and M8 and is the cheapest of the three; M8 depends on M7.

Phase 2 candidates remaining, in priority order: Axon file upload and download streaming, a Telepath server implementation.

---

## 8. Risks and Open Questions

**Surrogate strings poison the typed API.** `rawString` handles the codec correctly, but any `Codable` model with a `String` property will throw when it lands on one. Decide before M4 whether typed decoding replaces invalid sequences with U+FFFD by default (with a strict opt-in) or throws by default. Recommendation: replace by default, expose the raw bytes through a parallel accessor, since intelligence data is dirty and callers overwhelmingly want the query to finish.

**Backpressure across the NIO-to-AsyncSequence boundary.** A Storm query producing nodes faster than the consumer iterates will fill an unbounded buffer. Use `AsyncThrowingStream` with `.bufferingOldest(n)` and stop reading from the channel when the buffer is full, rather than buffering in userspace. Verify with a query returning a million nodes against a consumer that sleeps.

**Reconnect semantics — decided (2026-08-21).** A dropped main link invalidates the session, which invalidates every pool link. `Proxy` **surfaces the failure and never re-handshakes**, for the two reasons that decided it: a silent re-handshake loses server-side share state the caller still holds references to, and after a credential rotation it loops on `AuthDeny` instead of failing.

What was missing was the other half — a caller cannot reconnect deliberately if nothing tells it the link died. `Proxy.state` becomes an `AsyncStream<Proxy.State>` with cases `connected` and `disconnected(any Error)`, finishing when the proxy is closed. Reconnection is then a caller policy expressed as a new `Proxy`, which is the only construction that can honestly rebuild the session, the pool, and the caller's shares together.

`state` describes the *session*, not individual calls. A timed-out or cancelled call closes its own pool link (§3.8) and the session survives, so it must not report `disconnected`; only the main link dropping ends the session. Reporting otherwise would make the signal useless for the thing it exists for.

Two constraints on the stream, both learned the hard way elsewhere in this client: it must not retain the proxy (a stream nobody drains would otherwise keep an actor and its event loop group alive forever), and a consumer that stops iterating must not stall the proxy — state changes are dropped for a slow consumer rather than buffered without bound. `AsyncStream(bufferingPolicy: .bufferingNewest(2))` gives both. Two rather than one because that is the stream's entire lifetime — `connected` at subscription and at most one `disconnected` — and a bound of one would evict the `connected` a subscriber has not read yet when the link drops immediately after, contradicting the contract the stream exists to provide.

AHA pools (§3.9) are the one place the client reconnects on its own, and they do not contradict this: a pool member is not the caller's session, the pool owns those connections outright, and pool reset is observable through the same `state` stream.

**Cert directory format is undocumented and Synapse-specific.** Reading it may require tracking `synapse/lib/certdir.py`. If it proves unstable, drop it from v1 and require callers to supply PEM data directly.

**Generator link cost.** One TCP connection per concurrent Storm query is expensive for a mobile client on cellular. Measure before assuming the Python water marks (4/12) suit an iOS app. They probably do not. Make them configurable, which the `Config` type already does, and ship different defaults per platform.

**No protocol stability guarantee.** Vertex can change Telepath in any minor release. Mitigation is the weekly drift job plus the explicit version pin, not optimism.

**Synapse 3.0 is released and the facade does not work against it.** The wire protocol does: a 3.0 Cortex handshakes, calls, and streams with no codec or transport change. What broke is `Sources/Synapse` — keyword-only Storm arguments, a restructured `node` payload, and a data model without `inet:ipv4` — plus two version-representation bugs in `Sources/Telepath`. Measured, not estimated: see [docs/synapse-3.0.md](docs/synapse-3.0.md). **Decided (2026-08-21):** the facade models Synapse 2.x only, and `Cortex` refuses a server reporting any other major with `CortexError.unsupportedSynapseVersion` rather than decoding its nodes wrong. `Telepath` is unaffected and stays version agnostic, so a caller who needs 3.x today uses `Proxy` directly. Revisit when 3.x adoption justifies the work; the leading candidate is parallel `Synapse` / `Synapse3` modules over the shared core, not a runtime-adaptive `Node`, because `iden` and `nid` are different identifiers rather than different spellings of one.

---

## 9. References

All sources are the Synapse repository at `2.249.0`.

- `synapse/telepath.py`: client proxy, handshake, task v2, pool, URL parsing, TLS setup
- `synapse/daemon.py`: server handlers, `t2call`, response shapes
- `synapse/lib/link.py`: transport, read and write loop, cert pinning, CN check
- `synapse/lib/msgpack.py`: packer and unpacker configuration, ext hooks
- `synapse/lib/reflect.py`: `getShareInfo`, the `meths` and `genr` metadata
- `synapse/common.py`: `retnexc`, `err`, `result`, the retn tuple contract
- `synapse/lib/view.py`: Storm message stream
- `synapse/lib/cell.py`: `features` dictionary contents
- `synapse/lib/aha.py`: `iterPoolTopo`, `_getAhaName`, pool storage and windows
- `synapse/lib/urlhelp.py`: `chopurl`, the `urlinfo` shape `aha://` merges into