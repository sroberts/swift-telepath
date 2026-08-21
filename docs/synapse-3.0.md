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

### 3. Storm API arguments became keyword-only — but not in our code

| | 2.249.0 | 3.0.0 |
|---|---|---|
| `CoreApi.storm` | `(self, text, opts=None)` | `(self, text, *, opts=None)` |
| `CoreApi.callStorm` | `(self, text, opts=None)` | `(self, text, *, opts=None)` |
| `CoreApi.count` | `(self, text, opts=None)` | `(self, text, *, opts=None)` |

`Sources/Synapse/Cortex.swift` already passes `opts` as a keyword, so the facade
is unaffected. The `TypeError: CoreApi.storm() takes 2 positional arguments but 3
were given` failures come from the Telepath-level integration tests, which call
the raw Synapse API positionally (`IntegrationTests.swift:69` and friends). Those
tests are pinned to the 2.x model in other ways too — `inet:ipv4` no longer
exists — so there is nothing to fix here until the 3.0 decision is made.

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

## Status

Findings 1 and 2 are **fixed** (`41607f9`): both version shapes parse, string-valued
features score by major version, and `capture.py` records the version correctly.
Verified against both live servers — 2.249.0 still passes 152/152, and 3.0.0 now
reports `serverVersion == [3, 0, 0]` and decodes `getCellInfo`.

## Decision

Findings 4 through 6 are a facade and data-model project, not a protocol one, and
they are **not** being chased before 1.0. `Sources/Synapse` models Synapse 2.x,
and `Cortex` now refuses any other major outright.

That refusal is the point rather than a side effect. Before it, a 3.x server did
not fail — `Node.init` read a missing `iden` as nil and copied each
`(value, metadata)` prop tuple through untouched, so every property came back
wrong from a node that decoded cleanly. Silent wrong data is worse than no data,
particularly for intelligence work.

`Telepath` is unaffected and stays version agnostic; a caller who needs 3.x today
uses `Proxy` directly, which this spike verified end to end against 3.0.0.

When 3.x adoption justifies the work, the leading candidate is parallel `Synapse`
and `Synapse3` modules over the shared core rather than a runtime-adaptive
`Node`: `iden` and `nid` are different identifiers, not different spellings of
one, and a type that hides that would compile, run, and be wrong.
