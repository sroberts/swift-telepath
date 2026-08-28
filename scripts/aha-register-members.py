"""Registers the test Cortexes with a live AHA and holds the registration open.

`online` is not a flag a caller sets: AhaApi.addAhaSvc stores the *calling
session's* iden, and AHA's _clearInactiveSessions clears it when that session goes
away. So a service is online exactly as long as whoever registered it stays
connected. Registering and disconnecting leaves an entry every client skips --
Python's included -- which is what made the first version of this environment
unresolvable.

Full self-registration (`aha:name` in the cell config) is the production path, but
it makes each cell bind an ssl:// listener and needs the whole certificate chain.
From the client's side the two are indistinguishable: a real AHA, real records,
and a real session backing `online`.

Run detached; it holds the connection until killed.
"""

import asyncio
import os
import sys

import synapse.telepath as s_telepath

NETWORK = os.environ.get("NETWORK", "synapse")
AHA_URL = os.environ["AHA_URL"]
ALPHA_PORT = int(os.environ.get("ALPHA_PORT", "27601"))
BETA_PORT = int(os.environ.get("BETA_PORT", "27602"))

POOL = f"pool.{NETWORK}"
MEMBERS = {f"alpha.{NETWORK}": ALPHA_PORT, f"beta.{NETWORK}": BETA_PORT}


def svcinfo(port):
    return {
        "urlinfo": {
            "scheme": "tcp",
            "host": "127.0.0.1",
            "port": port,
            "user": "root",
            # In production a member is reached over ssl:// with a client
            # certificate and needs no password. This environment is plain tcp, so
            # the credential travels in urlinfo -- which also exercises the client's
            # handling of an AHA-supplied password.
            "passwd": "s3cret",
        },
    }


async def main():
    async with await s_telepath.openurl(AHA_URL) as aha:
        for name, port in MEMBERS.items():
            await aha.addAhaSvc(name, svcinfo(port))

        if await aha.getAhaPool(POOL) is None:
            await aha.addAhaPool(POOL, {})
        for name in MEMBERS:
            await aha.addAhaPoolSvc(POOL, name, {})

        # Report what the registry actually holds, so a mismatch between what this
        # intended and what AHA stored surfaces here rather than as a confusing
        # client failure later.
        pool = await aha.getAhaPool(POOL)
        print(f"pool {POOL}: {sorted(pool.get('services', {}))}", file=sys.stderr)
        for name in MEMBERS:
            info = (await aha.getAhaSvc(name)).get("svcinfo", {})
            print(f"svc {name}: online={bool(info.get('online'))} "
                  f"urlinfo={info.get('urlinfo')}", file=sys.stderr)
        sys.stderr.flush()

        # Holding the session is the point: dropping it takes every member offline.
        while True:
            await asyncio.sleep(3600)


asyncio.run(main())
