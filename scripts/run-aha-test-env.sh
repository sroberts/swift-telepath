#!/bin/sh
# Runs a real AHA registry with a real mirror pool, for M7/M8 integration tests.
#
# A scripted daemon can only confirm what this client already believes about AHA.
# This stands up the actual service: a real registry answering getAhaSvc and
# streaming iterPoolTopo, with two real Cortexes as pool members.
#
# `online` is not a flag: AhaApi.addAhaSvc stores the *calling session's* iden, and
# AHA clears it when that session goes away. A service is therefore online exactly
# as long as whoever registered it stays connected, and a registration that
# disconnects leaves an entry every client skips -- Python's included. So
# aha-register-members.py registers the members and then holds its connection open
# for the life of the environment.
#
# Full self-registration (`aha:name` in each cell's config) is the production path,
# but it makes every cell bind an ssl:// listener and needs the whole certificate
# chain. From the client's side the two are indistinguishable: a real AHA, real
# records, and a real session backing `online`.
#
#   ./scripts/run-aha-test-env.sh
#   TELEPATH_AHA_URL="tcp://root:s3cret@127.0.0.1:27600/" \
#   TELEPATH_AHA_POOL="pool.synapse" \
#   TELEPATH_AHA_SERVICE="alpha.synapse" swift test --filter AHAIntegrationTests
set -e

PYTHON="${PYTHON:-.venv-synapse/bin/python}"
ROOT="${AHA_TEST_ROOT:-.testaha}"
NETWORK="${AHA_NETWORK:-synapse}"

AHA_PORT="${AHA_PORT:-27600}"
ALPHA_PORT="${ALPHA_PORT:-27601}"
BETA_PORT="${BETA_PORT:-27602}"
AHA_URL="tcp://root:s3cret@127.0.0.1:$AHA_PORT/"

rm -rf "$ROOT"
mkdir -p "$ROOT/aha" "$ROOT/alpha" "$ROOT/beta"

# Synapse refuses to start a cell when the disk is near full, and nested cells read
# cell.yaml rather than the environment.
for d in "$ROOT/aha" "$ROOT/alpha" "$ROOT/beta"; do
    mkdir -p "$d/axon" "$d/jsonstor"
    printf 'limit:disk:free: 0\n' > "$d/axon/cell.yaml"
    printf 'limit:disk:free: 0\n' > "$d/jsonstor/cell.yaml"
done

printf 'limit:disk:free: 0\naha:network: %s\n' "$NETWORK" > "$ROOT/aha/cell.yaml"

export SYN_AHA_LIMIT_DISK_FREE=0
export SYN_CORTEX_LIMIT_DISK_FREE=0
export SYN_AXON_LIMIT_DISK_FREE=0
export SYN_JSONSTOR_LIMIT_DISK_FREE=0

wait_for_port() {
    i=0
    while [ "$i" -lt 120 ]; do
        if nc -z 127.0.0.1 "$1" 2>/dev/null; then return 0; fi
        i=$((i + 1))
        sleep 1
    done
    echo "server on $1 never started" >&2
    tail -30 "$ROOT"/*.log >&2
    exit 1
}

# Detached with output to a file: leaving stdout on the caller's pipe kills the
# server with BrokenPipeError on its next log write once that pipe closes.
nohup "$PYTHON" -m synapse.servers.aha \
    --telepath "tcp://127.0.0.1:$AHA_PORT/" --https 0 "$ROOT/aha" > "$ROOT/aha.log" 2>&1 &
wait_for_port "$AHA_PORT"

# AHA needs a password before anything can register against it.
"$PYTHON" -m synapse.tools.service.moduser \
    --svcurl "cell://$PWD/$ROOT/aha" --passwd s3cret root > /dev/null

for member in alpha:$ALPHA_PORT beta:$BETA_PORT; do
    name="${member%%:*}"
    port="${member##*:}"
    printf 'limit:disk:free: 0\n' > "$ROOT/$name/cell.yaml"
    nohup "$PYTHON" -m synapse.servers.cortex \
        --telepath "tcp://127.0.0.1:$port/" --https 0 "$ROOT/$name" \
        > "$ROOT/$name.log" 2>&1 &
    wait_for_port "$port"
    "$PYTHON" -m synapse.tools.service.moduser \
        --svcurl "cell://$PWD/$ROOT/$name" --passwd s3cret root > /dev/null
done

# Registers the members and holds the connection open. `online` is the registering
# session's iden, so the registration lasts exactly as long as this process does.
AHA_URL="$AHA_URL" NETWORK="$NETWORK" ALPHA_PORT="$ALPHA_PORT" BETA_PORT="$BETA_PORT" \
    nohup "$PYTHON" scripts/aha-register-members.py > "$ROOT/registrar.log" 2>&1 &

# Count the members, do not just look for one: the registrar prints a line each,
# and `grep -q` would declare success with beta still offline -- handing the test
# suite a half-configured environment, which is the failure this whole script
# exists to avoid.
EXPECTED_MEMBERS=2
i=0
while [ "$i" -lt 60 ]; do
    online=$(grep -c "online=True" "$ROOT/registrar.log" 2>/dev/null || echo 0)
    if [ "$online" -ge "$EXPECTED_MEMBERS" ]; then break; fi
    i=$((i + 1))
    sleep 1
done
online=$(grep -c "online=True" "$ROOT/registrar.log" 2>/dev/null || echo 0)
if [ "$online" -lt "$EXPECTED_MEMBERS" ]; then
    echo "only $online of $EXPECTED_MEMBERS members came online" >&2
    cat "$ROOT/registrar.log" >&2
    exit 1
fi
cat "$ROOT/registrar.log" >&2

echo "AHA        $AHA_URL"
echo "pool       aha://pool.$NETWORK"
echo "service    aha://alpha.$NETWORK"
echo "members    alpha.$NETWORK (:$ALPHA_PORT), beta.$NETWORK (:$BETA_PORT)"
