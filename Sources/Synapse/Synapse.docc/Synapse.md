# ``Synapse``

A typed facade over a Cortex: Storm queries, nodes, and user administration.

## Overview

```swift
let cortex = try await Cortex.open("tcp://root:secret@cortex.example.com:27492/")

for try await node in cortex.nodes("inet:ipv4=8.8.8.8 -> inet:dns:a") {
    print(node.form, node.value, node.tags.keys)
}

let count = try await cortex.callStorm("return((40 + 2))", returning: Int.self)
```

``Cortex/nodes(_:opts:)`` is the common path: it filters the Storm stream to
nodes and rethrows an `err` message as a Swift error. Use ``Cortex/storm(_:opts:)``
when prints, warnings and progress matter.

``StormMessage`` carries an ``StormMessage/other(name:data:)`` case on purpose:
Vertex adds message kinds between releases, and a client that throws on an
unknown kind breaks on upgrade.

## Topics

### Connecting

- ``Cortex``
- ``StormOpts``

### Storm

- ``StormStream``
- ``NodeStream``
- ``StormMessage``
- ``Node``
- ``StormInit``
- ``StormFini``
- ``StormWarn``
- ``StormError``

### Administration

- ``CellInfo``
- ``SynapseUser``
- ``SynapseRole``
