#!/bin/sh
# Stands up the TLS side of the conformance environment.
#
# Two listeners are needed, not one: Synapse sets CERT_REQUIRED on any listener
# whose URL carries ?ca=, so a listener that accepts client certificates cannot
# also serve password-authenticated clients.
#
#   27500  ssl://...?hostname=localhost                     password auth, CA trust, pinning
#   27501  ssl://...?hostname=localhost&ca=telepathtestca   client certificate auth
#
#   ./scripts/run-tls-test-cortex.sh
#   export TELEPATH_CERT_DIR="$PWD/.testcerts"
#   export TELEPATH_CERT_HASH="$(cat .testcerts/certhash)"
#   export TELEPATH_TLS_CLIENTCERT_PORT=27501
#   swift test --filter TLSIntegrationTests
set -e

PYTHON="${PYTHON:-.venv-synapse/bin/python}"
CERTDIR="${CERTDIR:-$PWD/.testcerts}"
CORTEX_DIRN="${CORTEX_DIRN:-$PWD/.testcortex/cortex-tls}"
CELL_DIRN="${CELL_DIRN:-$PWD/.testcortex/cell-clientcert}"
CANAME=telepathtestca
HOSTNAME_="${TLS_HOSTNAME:-localhost}"

# --- certificates -------------------------------------------------------------
if [ ! -f "$CERTDIR/cas/$CANAME.crt" ]; then
    mkdir -p "$CERTDIR"
    $PYTHON -m synapse.tools.utils.easycert --certdir "$CERTDIR" --ca "$CANAME"
    $PYTHON -m synapse.tools.utils.easycert --certdir "$CERTDIR" --server "$HOSTNAME_" --signas "$CANAME"
    # Synapse authenticates a TLS client by the certificate's common name, so the
    # certificate is issued to, and the cell user named, "{user}@{hostname}".
    $PYTHON -m synapse.tools.utils.easycert --certdir "$CERTDIR" --signas "$CANAME" "root@$HOSTNAME_"
fi

# The pin the client compares against: SHA-256 of the server certificate's DER.
$PYTHON - "$CERTDIR" "$HOSTNAME_" > "$CERTDIR/certhash" <<'PYEOF'
import sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes
import synapse.common as s_common
certdir, hostname = sys.argv[1], sys.argv[2]
with open(f'{certdir}/hosts/{hostname}.crt', 'rb') as fd:
    cert = x509.load_pem_x509_certificate(fd.read())
print(s_common.ehex(cert.fingerprint(hashes.SHA256())), end='')
PYEOF

export SYN_CERT_DIR="$CERTDIR"
export SYN_CORTEX_LIMIT_DISK_FREE=0 SYN_AXON_LIMIT_DISK_FREE=0
export SYN_JSONSTOR_LIMIT_DISK_FREE=0 SYN_CELL_LIMIT_DISK_FREE=0

for d in "$CORTEX_DIRN" "$CORTEX_DIRN/axon" "$CORTEX_DIRN/jsonstor" "$CELL_DIRN"; do
    mkdir -p "$d"
    printf 'limit:disk:free: 0\n' > "$d/cell.yaml"
done

# --- listeners ----------------------------------------------------------------
# Detached with output to files: leaving stdout on the caller's pipe kills the
# server with BrokenPipeError as soon as that pipe closes.
nohup $PYTHON -m synapse.servers.cortex \
    --telepath "ssl://0.0.0.0:27500/?hostname=$HOSTNAME_" --https 0 "$CORTEX_DIRN" \
    > "$CORTEX_DIRN/server.log" 2>&1 &

nohup $PYTHON -m synapse.servers.cell synapse.lib.cell.Cell "$CELL_DIRN" \
    --telepath "ssl://0.0.0.0:27501/?hostname=$HOSTNAME_&ca=$CANAME" --https 0 \
    > "$CELL_DIRN/server.log" 2>&1 &

echo "waiting for TLS listeners..."
i=0
while [ $i -lt 120 ]; do
    if [ -S "$CORTEX_DIRN/sock" ] && [ -S "$CELL_DIRN/sock" ]; then break; fi
    sleep 2
    i=$((i + 1))
done
[ -S "$CORTEX_DIRN/sock" ] || { echo "cortex failed to start"; tail -30 "$CORTEX_DIRN/server.log"; exit 1; }
[ -S "$CELL_DIRN/sock" ] || { echo "cell failed to start"; tail -30 "$CELL_DIRN/server.log"; exit 1; }

# --- users --------------------------------------------------------------------
$PYTHON -m synapse.tools.service.moduser --svcurl "cell://$CORTEX_DIRN" --passwd s3cret root > /dev/null

$PYTHON - "$CELL_DIRN" "root@$HOSTNAME_" <<'PYEOF'
import asyncio, sys
import synapse.telepath as s_telepath

async def main(dirn, username):
    async with await s_telepath.openurl(f'cell://{dirn}') as cell:
        # Idempotent: the cell directory survives between runs, so on a restart
        # the user already exists and addUser raises DupUser. That aborted the
        # script after the listeners were already up, leaving an environment that
        # looked broken but was merely half-configured.
        user = await cell.getUserDefByName(username)
        if user is None:
            user = await cell.addUser(username)
        await cell.setUserAdmin(user['iden'], True)

asyncio.run(main(sys.argv[1], sys.argv[2]))
PYEOF

echo "TLS listeners ready on 27500 (password/CA/pinning) and 27501 (client cert)"
echo "certhash: $(cat "$CERTDIR/certhash")"
