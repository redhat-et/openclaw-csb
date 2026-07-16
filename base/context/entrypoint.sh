#!/bin/bash
set -euo pipefail

# Write startup probe marker for kubelet/kagenti
touch /tmp/agent-ready

# If no arguments and AGENT_NAME is set, default to the agent binary
if [[ $# -eq 0 && -n "${AGENT_NAME:-}" ]]; then
    command -v "${AGENT_NAME}" > /dev/null 2>&1 || {
        echo "Error: ${AGENT_NAME} is not installed" >&2
        exit 1
    }
    exec "${AGENT_NAME}"
fi

exec "$@"
