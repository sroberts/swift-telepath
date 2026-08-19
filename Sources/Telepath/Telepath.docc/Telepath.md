# ``Telepath``

A client for Telepath, the msgpack RPC protocol that fronts every Synapse service.

## Overview

Telepath has no published specification: it is defined by its Python
implementation, and this client is pinned to Synapse 2.249.0. Three properties of
the protocol shape this API more than anything else.

**A link is dedicated to a call.** From `t2:init` until its terminator, one TCP
connection belongs to one call — including a generator streaming for hours. The
pool therefore bounds concurrency, not throughput, and a call that is abandoned,
cancelled or timed out closes its link rather than returning it, because a late
reply on a recycled link would be delivered to the next caller.

**There is no framing.** The link carries a continuous msgpack stream, so a
framing error has no resync point and is always fatal to the connection.

**Errors are data.** Every result is a `retn` tuple, and a remote exception is a
complete, well-formed exchange rather than a transport failure. It arrives as
``TelepathRemoteError`` with the server's exception name intact, and the link
stays usable.

## Connecting

```swift
let proxy = try await Proxy.open("tcp://root:secret@cortex.example.com:27492/")
let info = try await proxy.call("getCellInfo")
for try await message in proxy.stream("storm", [.string("inet:ipv4")], kwargs: ["opts": .map([:])]) {
    print(message)
}
await proxy.close()
```

For a typed Storm API, use `Cortex` in the `Synapse` module.

## Deadlines and cancellation

``Config/callTimeout`` is nil by default, matching Synapse, which sets no
client-side deadline. When set it bounds each *wait for a message* rather than a
whole conversation: for a unary call that is the call, and for a generator it is
the gap between yields, because a legitimate query can run for hours.

Task cancellation is honoured on every await that waits on the network, so a
parent task, a task group, or a test's time limit all unblock a stalled call.

## Topics

### Connecting

- ``Proxy``
- ``Config``
- ``TelepathURL``

### Calling

- ``TelepathStream``
- ``DecodedStream``
- ``Share``
- ``MethodInfo``
- ``ShareInfo``

### Errors

- ``TelepathError``
- ``TelepathRemoteError``
- ``TelepathErrorName``
