#!/bin/bash
# =============================================================================
# OpenClaw entrypoint — OpenShift-compatible startup script
#
# Responsibilities:
#   1. Bootstrap OPENCLAW_CONFIG_DIR if this is a first run
#   2. Write a minimal .env from injected environment variables
#      (API key + gateway token come from an OpenShift Secret)
#   3. Apply any additional config via the OpenClaw CLI config set command
#   4. exec the gateway process (PID 1)
#
# Environment variables expected (injected by OpenShift Secret):
#   OPENCLAW_GATEWAY_TOKEN  — shared secret for the Control UI
#   OPENCLAW_AI_ENV_VAR     — name of the provider env var (e.g. ANTHROPIC_API_KEY)
#   <PROVIDER>_API_KEY      — the actual API key value
#
# Optional:
#   OPENCLAW_DISABLE_BONJOUR — set to 1 to disable mDNS (default: 1 in containers)
#   OPENCLAW_LOG_LEVEL       — debug | info | warn | error (default: info)
# =============================================================================

set -euo pipefail

CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-/opt/openclaw/config}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/opt/openclaw/workspace}"
ENV_FILE="${CONFIG_DIR}/.env"
INITIALIZED_FLAG="${CONFIG_DIR}/.initialized"

echo "[entrypoint] Starting OpenClaw gateway..."
echo "[entrypoint] Config dir:    ${CONFIG_DIR}"
echo "[entrypoint] Workspace dir: ${WORKSPACE_DIR}"

# ---------------------------------------------------------------------------
# Ensure directories exist and are writable
# The PVC may have been freshly provisioned; subdirs may not exist yet
# ---------------------------------------------------------------------------
mkdir -p "${CONFIG_DIR}" "${WORKSPACE_DIR}"

# ---------------------------------------------------------------------------
# First-run bootstrap
# Write .env only if it doesn't already exist (idempotent across restarts)
# ---------------------------------------------------------------------------
if [[ ! -f "${INITIALIZED_FLAG}" ]]; then
    echo "[entrypoint] First run detected — bootstrapping config..."

    # Require gateway token
    if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
        echo "[entrypoint] ERROR: OPENCLAW_GATEWAY_TOKEN is not set." >&2
        echo "[entrypoint]        Generate one and store it in your OpenShift Secret." >&2
        exit 1
    fi

    # Write the .env file that OpenClaw reads at startup
    # Do NOT clobber if already present (e.g. manual edits persisted on PVC)
    if [[ ! -f "${ENV_FILE}" ]]; then
        cat > "${ENV_FILE}" <<EOF
# OpenClaw runtime environment — written by entrypoint.sh on first run
# This file is persisted on the config PVC. Edit carefully.

OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
OPENCLAW_DISABLE_BONJOUR=1
NODE_ENV=production
EOF
        echo "[entrypoint] Wrote ${ENV_FILE}"
    fi

    # Run the non-interactive onboard (skips interactive API key prompts;
    # keys are picked up from env vars injected by the OpenShift Secret)
    echo "[entrypoint] Running onboard (non-interactive, local mode)..."
    node /app/dist/index.js onboard \
        --mode local \
        --no-install-daemon \
        --yes 2>&1 || true
    # Note: --yes may not suppress all prompts on every OpenClaw version.
    # If the container hangs on onboard, set OPENCLAW_SKIP_ONBOARD=1 and
    # the block below will skip straight to the gateway start.

    # Apply baseline gateway config.
    # gateway.bind must be "lan" (0.0.0.0) so the OpenShift router can reach
    # the pod. Loopback-only binding (the default) is unreachable from outside
    # the pod and the Route health checks will never pass.
    #
    # gateway.controlUi.allowedOrigins must include the public Route URL or
    # the browser gets a CORS rejection when loading the Control UI from the
    # OpenShift Route hostname. OPENCLAW_PUBLIC_URL is injected by the
    # Ansible playbook after the Route hostname is known.
    echo "[entrypoint] Applying gateway config..."
    ALLOWED_ORIGINS='["http://localhost:18789","http://127.0.0.1:18789"'
    if [[ -n "${OPENCLAW_PUBLIC_URL:-}" ]]; then
        ALLOWED_ORIGINS="${ALLOWED_ORIGINS},"${OPENCLAW_PUBLIC_URL}""
        echo "[entrypoint] Adding ${OPENCLAW_PUBLIC_URL} to controlUi.allowedOrigins"
    fi
    ALLOWED_ORIGINS="${ALLOWED_ORIGINS}]"

    node /app/dist/index.js config set --batch-json \
        "[
            {"path":"gateway.mode","value":"local"},
            {"path":"gateway.bind","value":"lan"},
            {"path":"gateway.controlUi.allowedOrigins","value":${ALLOWED_ORIGINS}}
        ]" 2>&1 || true

    touch "${INITIALIZED_FLAG}"
    echo "[entrypoint] Bootstrap complete."
else
    echo "[entrypoint] Config already initialized — skipping bootstrap."
fi

# ---------------------------------------------------------------------------
# Apply channel configuration (idempotent on every start)
#
# The channel ConfigMap is mounted at $OPENCLAW_CHANNEL_CONFIG_PATH.
# It contains the channels.* config structure with ${ENV_VAR} placeholders
# that OpenClaw resolves at startup from the injected Secret env vars.
# We apply it every time (not just on first run) so that playbook changes
# take effect on pod restart without needing to delete the .initialized flag.
# ---------------------------------------------------------------------------
CHANNEL_CONFIG_PATH="${OPENCLAW_CHANNEL_CONFIG_PATH:-}"

if [[ -n "${CHANNEL_CONFIG_PATH}" && -f "${CHANNEL_CONFIG_PATH}" ]]; then
    echo "[entrypoint] Applying channel configuration from ${CHANNEL_CONFIG_PATH}..."

    # Read the JSON and pass it to config set as a single-path merge
    # openclaw config set --path channels --value '<json>' merges the
    # channels block into the live config without clobbering other keys.
    CHANNELS_JSON=$(node -e "
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync('${CHANNEL_CONFIG_PATH}', 'utf8'));
        // Flatten to batch-json array: [{path, value}, ...]
        const items = Object.entries(cfg.channels || {}).map(([id, val]) => ({
            path: 'channels.' + id,
            value: val
        }));
        process.stdout.write(JSON.stringify(items));
    " 2>/dev/null) || true

    if [[ -n "${CHANNELS_JSON}" && "${CHANNELS_JSON}" != "[]" ]]; then
        node /app/dist/index.js config set --batch-json "${CHANNELS_JSON}" 2>&1 \
            && echo "[entrypoint] Channel config applied." \
            || echo "[entrypoint] WARNING: channel config set returned non-zero — check config syntax."
    else
        echo "[entrypoint] No channel entries found in config file — skipping."
    fi
else
    echo "[entrypoint] No channel config path set — running gateway-only (no messaging channels)."
fi

# ---------------------------------------------------------------------------
# Start the gateway (replaces this shell process as PID 1)
# ---------------------------------------------------------------------------
echo "[entrypoint] Launching OpenClaw gateway on port 18789..."
exec node /app/dist/index.js gateway
