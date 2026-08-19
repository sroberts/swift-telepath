# ``Msgpack``

A msgpack codec matching Synapse's packer, which deviates from the standard in two
ways that matter.

## Overview

**Integers wider than 64 bits** ride as ext type 0 (unsigned) or ext type 1
(signed two's complement) and decode to ``MsgpackValue/bigInt(sign:magnitude:)``.
Ext 1's width follows Python's `(bit_length + 8) // 8`, which is deliberately not
minimal — `-2**127` occupies 17 bytes where 16 would do — and that padding is part
of the wire format.

**Strings are packed with `unicode_errors='surrogatepass'`**, so a msgpack `str`
may contain UTF-8 encoded lone surrogates that Swift's `String` cannot represent.
Those decode to ``MsgpackValue/rawString(_:)`` and round-trip byte for byte.
Failing a whole message because one property is dirty would make the library
unusable against real Cortex data.

Integers compare numerically across cases: msgpack draws no wire distinction
between signed and unsigned, so `.int(5)`, `.uint(5)` and a `.bigInt` of the same
value are equal and hash equally.

## Topics

### Values

- ``MsgpackValue``

### Coding

- ``MsgpackPacker``
- ``MsgpackUnpacker``
- ``MsgpackStreamUnpacker``
- ``MsgpackEncoder``
- ``MsgpackDecoder``
- ``MsgpackError``
