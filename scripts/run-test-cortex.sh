#!/bin/sh
# Runs a local Synapse Cortex for conformance testing.
#
# Telepath has no published specification, so integration tests against a real
# Cortex are what actually establish conformance. This uses the pinned Synapse
# release installed in .venv-synapse (see scripts/setup-test-env.sh).
#
#   ./scripts/run-test-cortex.sh            # starts on tcp://127.0.0.1:27492
#   TELEPATH_TEST_URL="tcp://root:s3cret@127.0.0.1:27492/" swift test
set -e

DIRN="${CORTEX_DIRN:-.testcortex/cortex00}"
PYTHON="${PYTHON:-.venv-synapse/bin/python}"

# Nested cells (axon, jsonstor) take config from their own cell.yaml rather than
# the environment, so the disk-free guard is disabled per-directory. It is a dev
# machine concern, unrelated to Telepath.
mkdir -p "$DIRN/axon" "$DIRN/jsonstor"
for d in "$DIRN" "$DIRN/axon" "$DIRN/jsonstor"; do
    printf 'limit:disk:free: 0\n' > "$d/cell.yaml"
done

export SYN_CORTEX_LIMIT_DISK_FREE=0
export SYN_AXON_LIMIT_DISK_FREE=0
export SYN_JSONSTOR_LIMIT_DISK_FREE=0

exec "$PYTHON" -m synapse.servers.cortex \
    --telepath tcp://127.0.0.1:27492/ --https 0 "$DIRN"
