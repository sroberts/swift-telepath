"""Generate msgpack conformance vectors from the pinned Synapse release.

Telepath has no published specification, so the codec's contract is whatever
synapse.lib.msgpack does. This emits a JSON manifest the Swift test suite
replays in both directions: decode(hex) == expected value, and encode(value)
== the same hex, byte for byte.

Usage:  uv run --python ../.venv-synapse python tools/genvectors.py > Tests/MsgpackTests/vectors.json
"""
import json
import sys

import synapse.lib.msgpack as s_msgpack

VECTORS = []


def add(desc, obj, *, kind, expect=None, roundtrip=True):
    """Pack obj with Synapse's packer and record the bytes.

    kind/expect describe the value the Swift decoder must produce, spelled in a
    small tagged form so the test does not have to re-derive Python semantics.

    A value the release cannot pack is recorded as unsupported rather than raising.
    Synapse 3.0.0 dropped unicode_errors='surrogatepass', so lone surrogates became
    unserialisable; the drift job needs to report that as a finding, not die on it.
    """
    try:
        buf = s_msgpack.en(obj)
    except Exception as e:                              # noqa: BLE001
        VECTORS.append({
            "description": desc,
            "pythonRepr": repr(obj),
            "hex": None,
            "kind": kind,
            "expect": expect,
            "roundtrip": False,
            "unsupported": f"{type(e).__name__}: {e}",
        })
        return
    if kind == "bigint":
        # Emit sign + magnitude hex so the Swift test compares structurally
        # instead of re-implementing arbitrary-precision decimal parsing.
        mag = abs(obj)
        expect = {
            "sign": "-" if obj < 0 else "+",
            "magHex": mag.to_bytes((mag.bit_length() + 7) // 8, "big").hex(),
        }
    VECTORS.append({
        "description": desc,
        "pythonRepr": repr(obj),
        "hex": buf.hex(),
        "kind": kind,
        "expect": expect,
        # False where Python's packer is not the canonical form we re-emit.
        "roundtrip": roundtrip,
        "unsupported": None,
    })


# --- integers, especially the boundaries where ext types take over ------------
add("zero", 0, kind="int", expect="0")
add("positive fixint max", 127, kind="int", expect="127")
add("negative fixint min", -32, kind="int", expect="-32")
add("int64 min", -(2**63), kind="int", expect=str(-(2**63)))
add("uint64 max", 2**64 - 1, kind="uint", expect=str(2**64 - 1))
add("uint64 max + 1 (ext 0)", 2**64, kind="bigint", expect=str(2**64))
add("int64 min - 1 (ext 1)", -(2**63) - 1, kind="bigint", expect=str(-(2**63) - 1))
add("big positive, 40 byte magnitude", 2 ** 319 + 12345, kind="bigint", expect=str(2 ** 319 + 12345))
add("big negative, 40 byte magnitude", -(2 ** 319) - 12345, kind="bigint", expect=str(-(2 ** 319) - 12345))
add("ext 0 boundary exact power", 2**128, kind="bigint", expect=str(2**128))
add("ext 1 large negative power", -(2**128), kind="bigint", expect=str(-(2**128)))
# -2**127 is where Python's width formula stops being minimal; byte-exact
# re-encoding has to reproduce the padding, not just the value.
add("ext 1 non-minimal width", -(2**127), kind="bigint", expect=str(-(2**127)))

# --- str vs bytes under use_bin_type -----------------------------------------
add("empty string", "", kind="string", expect="")
add("ascii string", "hello", kind="string", expect="hello")
add("unicode string", "é中\U0001f600", kind="string", expect="é中\U0001f600")
add("empty bytes", b"", kind="binary", expect="")
add("bytes", b"\x00\x01\xfe\xff", kind="binary", expect="0001feff")
add("str8 boundary 32 chars", "x" * 32, kind="string", expect="x" * 32)
add("str16 boundary 256 chars", "y" * 256, kind="string", expect="y" * 256)

# --- surrogatepass: strings Swift's String cannot hold ------------------------
add("lone high surrogate", "\ud800", kind="rawstring", expect="eda080")
add("lone low surrogate embedded", "a\udfffb", kind="rawstring", expect="61edbfbf62")
add("astral plane char is valid utf8", "😀", kind="string", expect="😀")
add("surrogate pair spelled separately", "\ud83d\ude00", kind="rawstring", expect="eda0bdedb880")

# --- map keys are not guaranteed to be strings --------------------------------
add("integer map keys", {1: "a", 2: "b"}, kind="map", expect=None)
add("tuple map key", {(1, 2): "pair"}, kind="map", expect=None)
add("mixed key types", {"s": 1, 7: "i"}, kind="map", expect=None)

# --- containers ---------------------------------------------------------------
add("empty array", (), kind="array", expect=None)
add("empty map", {}, kind="map", expect=None)
add("nested 8 deep", (((((((((1,),),),),),),),),), kind="array", expect=None)
add("telepath t2:init shape", ("t2:init", {
    "todo": ("getCellInfo", (), {}),
    "name": None,
    "sess": "a" * 32,
}), kind="array", expect=None)

# --- floats -------------------------------------------------------------------
add("float", 1.5, kind="double", expect="1.5")
add("negative zero", -0.0, kind="double", expect="-0.0")
add("infinity", float("inf"), kind="double", expect="inf")
add("negative infinity", float("-inf"), kind="double", expect="-inf")
add("nan", float("nan"), kind="double", expect="nan")

# --- misc ---------------------------------------------------------------------
add("none", None, kind="null", expect=None)
add("true", True, kind="bool", expect="true")
add("false", False, kind="bool", expect="false")

# --- large payloads ------------------------------------------------------------
# Storing a 20 MiB blob as hex would add 40 MB to the repository, so these record
# a checksum of the packed bytes instead. The Swift test builds the same value,
# packs it, and compares length and digest.
DIGEST_VECTORS = []


def fnv1a64(data):
    """FNV-1a, chosen because it is trivial to reimplement identically in Swift."""
    h = 0xcbf29ce484222325
    for byte in data:
        h ^= byte
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def add_digest(desc, obj, kind, *, detail=None):
    try:
        buf = s_msgpack.en(obj)
    except Exception as e:                              # noqa: BLE001
        DIGEST_VECTORS.append({
            "description": desc, "kind": kind, "detail": detail,
            "byteLength": 0, "headerHex": "", "fnv1a64": "0",
            "unsupported": f"{type(e).__name__}: {e}",
        })
        return
    DIGEST_VECTORS.append({
        "description": desc,
        "kind": kind,
        "detail": detail,
        "byteLength": len(buf),
        "headerHex": buf[:8].hex(),
        "fnv1a64": str(fnv1a64(buf)),
        "unsupported": None,
    })


# 20 MiB exercises chunked socket reads and the bin32 header.
add_digest("20 MiB binary blob", bytes(i % 251 for i in range(20 * 1024 * 1024)),
           "binary", detail="i % 251")
add_digest("1 MiB ascii string", "z" * (1024 * 1024), "string", detail="z repeated")
add_digest("100k element integer array", tuple(range(100_000)), "array", detail="range")
add_digest("10k entry map", {f"key{i}": i for i in range(10_000)}, "map", detail="key{i}: i")

json.dump({
    # synapse.version is a tuple in 2.x and a string in 3.0; normalise both.
    "synapseVersion": (lambda v: v if isinstance(v, str) else ".".join(str(p) for p in v))(
        __import__("synapse").version),
    "vectors": VECTORS,
    "digestVectors": DIGEST_VECTORS,
}, sys.stdout, indent=2)
