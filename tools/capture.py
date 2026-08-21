"""Record real Telepath exchanges for replay against the Swift client.

Sits between a client and a real Cortex, decoding the msgpack stream in both
directions with Synapse's own unpacker and writing one JSON file per run. The
result is a corpus of genuine server behaviour — including messages this client
does not implement yet, such as t2:share — that tests can replay without a server.

  python tools/capture.py --listen 27493 --upstream 127.0.0.1:27492 \
      --out Tests/TelepathTests/protocol-vectors.json --label unary-call
"""
import argparse
import asyncio
import json
import signal
import sys

import synapse.lib.msgpack as s_msgpack

CONNECTIONS = []


def _synapse_version():
    """The running Synapse version as a dotted string, either shape."""
    version = __import__("synapse").version
    if isinstance(version, str):
        return version
    return ".".join(str(part) for part in version)



class Recorder:
    """One proxied connection. Telepath opens several: a main link created by the
    handshake, plus one per in-flight call, so they are recorded separately."""

    def __init__(self, index):
        self.index = index
        self.messages = []

    def record(self, direction, chunk, unpacker):
        unpacker.feed(chunk)
        while True:
            try:
                message = unpacker.unpack()
            except s_msgpack.msgpack.OutOfData:
                return
            except Exception as e:                      # noqa: BLE001
                print(f"decode error: {e}", file=sys.stderr)
                return
            self.messages.append({
                "direction": direction,
                "name": message[0] if isinstance(message, (list, tuple)) and message else None,
                "hex": s_msgpack.en(message).hex(),
            })


async def pump(reader, writer, recorder, direction):
    # A streaming unpacker configured exactly as Synapse configures its own.
    unpacker = s_msgpack.msgpack.Unpacker(
        raw=False, use_list=False, strict_map_key=False,
        max_buffer_size=2**32 - 1, ext_hook=s_msgpack._ext_un,
    )
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            recorder.record(direction, chunk, unpacker)
            writer.write(chunk)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        try:
            writer.close()
        except Exception:                               # noqa: BLE001
            pass


async def handle(client_reader, client_writer, upstream):
    recorder = Recorder(len(CONNECTIONS))
    CONNECTIONS.append(recorder)
    try:
        # Unix upstreams matter because cell:// services auto-authenticate the
        # connection as root, which is how share-returning APIs are reachable.
        if upstream.startswith("/"):
            server_reader, server_writer = await asyncio.open_unix_connection(upstream)
        else:
            host, port = upstream.rsplit(":", 1)
            server_reader, server_writer = await asyncio.open_connection(host, int(port))
    except OSError as e:
        print(f"upstream connect failed: {e}", file=sys.stderr)
        client_writer.close()
        return
    await asyncio.gather(
        pump(client_reader, server_writer, recorder, "c2s"),
        pump(server_reader, client_writer, recorder, "s2c"),
        return_exceptions=True,
    )


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", type=int, default=27493)
    parser.add_argument("--upstream", default="127.0.0.1:27492",
                        help="host:port, or an absolute path for a unix socket")
    parser.add_argument("--out", required=True)
    parser.add_argument("--label", required=True, help="scenario name for this capture")
    parser.add_argument("--seconds", type=float, default=30.0)
    args = parser.parse_args()

    server = await asyncio.start_server(
        lambda r, w: handle(r, w, args.upstream), "127.0.0.1", args.listen)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    print(f"recording on 127.0.0.1:{args.listen} -> {args.upstream}", file=sys.stderr)
    try:
        await asyncio.wait_for(stop.wait(), timeout=args.seconds)
    except asyncio.TimeoutError:
        pass

    server.close()
    await server.wait_closed()
    await asyncio.sleep(0.2)

    scenario = {
        "label": args.label,
        # 2.x exposes synapse.version as a tuple, 3.0 as a string. Joining a
        # string iterates its characters and records "3...0...0".
        "synapseVersion": _synapse_version(),
        "connections": [
            {"index": c.index, "messages": c.messages}
            for c in CONNECTIONS if c.messages
        ],
    }

    try:
        with open(args.out) as f:
            document = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        document = {"scenarios": []}

    document["scenarios"] = [s for s in document["scenarios"] if s["label"] != args.label]
    document["scenarios"].append(scenario)
    document["scenarios"].sort(key=lambda s: s["label"])

    with open(args.out, "w") as f:
        json.dump(document, f, indent=2)

    total = sum(len(c["messages"]) for c in scenario["connections"])
    print(f"captured {total} messages across {len(scenario['connections'])} connections "
          f"for '{args.label}'", file=sys.stderr)


if __name__ == "__main__":
    asyncio.run(main())
