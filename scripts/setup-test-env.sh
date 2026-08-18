#!/bin/sh
# Installs the pinned Synapse release used to generate codec vectors and to run
# the integration Cortex. Keep the version in step with Package.swift's
# SYNAPSE_PINNED_VERSION comment and with README.md.
set -e
SYNAPSE_VERSION="${SYNAPSE_VERSION:-2.249.0}"

uv venv --python 3.11 .venv-synapse
uv pip install --python .venv-synapse "synapse==${SYNAPSE_VERSION}"

echo "Installed synapse ${SYNAPSE_VERSION}."
echo "Regenerate codec vectors with:"
echo "  .venv-synapse/bin/python tools/genvectors.py > Tests/MsgpackTests/vectors.json"
