# Synapse 3.0 compatibility spike

**Date:** 2026-08-21 · **Tested against:** Synapse 3.0.0 (commit
`f2c0f631c278d91db55fc7da5897987aaf88958a`), compared with the pinned 2.249.0.

**Verdict: the Telepath layer is compatible with 3.0. The Synapse facade is not.**

A 3.0 Cortex connects, handshakes, authenticates, runs unary calls, streams
generators, and returns errors as `retn` tuples, all without a single codec,
framing, or transport change. Every one of the 16 failing tests fails inside
`Sources/Synapse` or on an assertion about Synapse's own version string — not on
the wire protocol.

## Method

A 3.0 Cortex on `tcp://127.0.0.1:27494/`, the full suite run against it with
`TELEPATH_REQUIRE_INTEGRATION=1`, and the handshake captured byte-for-byte
through `tools/capture.py`. Every claim below is either a captured message or a
line of upstream source, per CLAUDE.md's rule that protocol questions are
answered by reading Synapse, never by inference.

```
136 passed · 16 failed · 0 codec or framing failures
```

## What did not change

`tele:syn` still negotiates `vers = (3, 0)`. `retn` is still `(True, None)`.
`sess` is still present and still a 32-char hex guid, which matters more than
anything else here: it is the only thing binding a pool link to an authenticated
session, and pool links still skip the handshake and carry it in `t2:init`.
Generators still terminate on `t2:fini`, errors still arrive as `(False, (name,
info))`, and the stream is still unframed msgpack in Python's dialect.

## What changed

### 1. Version representation: tuple → string

`sharinfo['syn:version']` is `'3.0.0'` in 3.0 and `(2, 249, 0)` in 2.x. The same
change hits `getCellInfo()`'s `synapse.version`.

- `Proxy.serverVersion` (`Sources/Telepath/Messages.swift:31`) reads
  `arrayValue`, so it returns `nil` against 3.0 rather than failing loudly.
- `CortexInfo` decoding throws `.typeMismatch(expected: "array", actual:
  "string", path: "synapse.version")`.
- `tools/capture.py:122` does `".".join(str(p) for p in synapse.version)`, which
  against a string iterates characters and records `"3...0...0"`.
  `tools/genvectors.py` already normalises this; `capture.py` was never updated.

This is the only finding that touches `Sources/Telepath`.

### 2. `features` is empty

Upstream `synapse/lib/cell.py:1223` in 2.249 sets five features (`tellready`,
`dynmirror`, `tasks`, `issuewait`, `shutdowndrain`). In 3.0, `cell.py:1007` sets
`self.features = {}` and adds only `stormservice = '1.0.0'`, and only for a cell
whose API subclasses `StormSvc`. The advertised capabilities became unconditional
and the advertisement was dropped.

Two consequences. `hasFeature("tasks")` is now false against a server that
plainly supports task v2 — which is harmless for us, because `hasFeature` is
declared at `Sources/Telepath/Proxy.swift:220` and never called anywhere in
`Sources`; we gate on `sess` presence instead. It is not harmless for a consumer
who followed the documented forward-compatibility mechanism.

Second, `features` is typed `[String: Int]`, and 3.0's only feature value is the
**string** `'1.0.0'`. It currently decodes to `0`, so `hasFeature(_:minVersion:)`
would reject a feature the server does advertise.

### 3. Storm API arguments became keyword-only

| | 2.249.0 | 3.0.0 |
|---|---|---|
| `CoreApi.storm` | `(self, text, opts=None)` | `(self, text, *, opts=None)` |
| `CoreApi.callStorm` | `(self, text, opts=None)` | `(self, text, *, opts=None)` |
| `CoreApi.count` | `(self, text, opts=None)` | `(self, text, *, opts=None)` |

The facade passes `opts` positionally, so 3.0 answers `TypeError: CoreApi.storm()
takes 2 positional arguments but 3 were given`. Passing it as a keyword works
against **both** versions, so this one is a strict improvement rather than a
fork.

### 4. `repr` moved inside `node:opts`

3.0's storm opts schema sets `additionalProperties: false` and no longer has a
top-level `repr`; it now lives at `node:opts.repr` alongside new `links`,
`virts`, `storage`, and `embeds` keys. Sending the old shape is rejected outright
with `SchemaViolation: data must not contain {'repr'} properties`.

### 5. The `node` message payload was restructured

| 2.x | 3.0 |
|---|---|
| `iden` (32-char buid hex) | `nid` (short integer-as-string, e.g. `'8'`) |
| `.created` as a prop | `meta: {created, updated}` |
| `props: {name: value}` | `props: {name: (value, {'t': type})}` |
| — | `n1verbs` / `n2verbs` (edges) |
| `nodedata` | absent from this shape |

`props` values becoming 2-tuples is the expensive one: `Node` decodes them as
scalars today, so every property on every node decodes wrong rather than failing
cleanly.

### 6. The data model changed

3.0 ships 560 forms. `inet:ipv4` is **not** among them (102 `inet:*` forms
remain), and the `test:*` forms are not loaded by default. Several suite failures
(`NoSuchForm`, `NoSuchTagProp: score`, `NoSuchName: Cannot find name [true]`) are
queries written against the 2.x model, not client defects.

### 7. Smaller observations

- Error `info` maps now carry a `highlight` key (`hash`, `lines`, `columns`,
  `offsets`). Decoding tolerates it, as unknown-key forward compatibility
  requires.
- `synapse.tools.service.moduser` renamed `--svcurl` to `--url`. CI uses the old
  spelling at `.github/workflows/ci.yml:112`.
- A 3.0 cell logs `NotReady: No aha servers registered to lookup jsonstor` at
  boot and starts anyway. Nested cells appear to expect AHA in 3.0.

## Recommendation

Do not chase 3.0 before tagging 1.0. Findings 1 and 2 are the only ones inside
`Sources/Telepath`, they are small, and both are version-representation
robustness rather than protocol change — worth fixing now precisely because they
are cheap and because `serverVersion` returning `nil` is a silent wrong answer.
Finding 3 is a one-line change that improves 2.x too.

Findings 4 through 6 are a facade and data-model project, not a protocol one.
They need a decision this spike cannot make: whether `Sources/Synapse` supports
both model generations behind one API, or whether the package pins a Synapse
major and 3.0 gets its own release track. That decision belongs in `spec.md`
before any code moves.
