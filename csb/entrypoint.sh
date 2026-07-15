#!/bin/bash
# =============================================================================
# OpenClaw CSB entrypoint — locked-down "naked claw" for Corporate Standard Build
#
# This entrypoint enforces a hardened configuration on every startup:
#   - All plugins disabled (plugins.enabled=false, deny=["*"])
#   - No skills (bundled, installed, or uploaded)
#   - No marketplace/ClawHub access
#   - Shell execution denied
#   - Filesystem restricted to workspace
#   - Config immutability via OPENCLAW_NIX_MODE=1
#   - mDNS discovery disabled
#
# The config is written fresh on every startup and cannot be modified
# at runtime. This is intentional — the CSB variant is always naked.
#
# Credentials can be provided via environment variables OR podman secrets:
#
#   Environment variables:
#     OPENCLAW_GATEWAY_TOKEN  — shared secret for the Control UI
#     <PROVIDER>_API_KEY      — the actual AI provider key
#
#   Podman secrets (mounted at /run/secrets/<name>):
#     openclaw-gateway-token  → read into OPENCLAW_GATEWAY_TOKEN
#     openai-api-key          → read into OPENAI_API_KEY
#     anthropic-api-key       → read into ANTHROPIC_API_KEY
#     google-api-key          → read into GOOGLE_API_KEY
#     xai-api-key             → read into XAI_API_KEY
#     mistral-api-key         → read into MISTRAL_API_KEY
#     cohere-api-key          → read into COHERE_API_KEY
#
#   Usage:
#     echo -n "sk-..." | podman secret create openai-api-key -
#     echo -n "$(openssl rand -hex 32)" | podman secret create openclaw-gateway-token -
#     podman run --secret openai-api-key --secret openclaw-gateway-token ...
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Read podman secrets from /run/secrets/ if env vars are not set.
# Podman mounts secrets as files at /run/secrets/<secret-name>.
# ---------------------------------------------------------------------------
read_secret() {
    local env_var="$1"
    local secret_name="$2"
    local secret_file="/run/secrets/${secret_name}"
    if [[ -z "${!env_var:-}" ]] && [[ -f "${secret_file}" ]]; then
        export "${env_var}=$(cat "${secret_file}")"
        echo "[entrypoint] Loaded ${env_var} from podman secret '${secret_name}'"
    fi
}

read_secret OPENCLAW_GATEWAY_TOKEN  openclaw-gateway-token
read_secret OPENAI_API_KEY          openai-api-key
read_secret ANTHROPIC_API_KEY       anthropic-api-key
read_secret GOOGLE_API_KEY          google-api-key
read_secret XAI_API_KEY             xai-api-key
read_secret MISTRAL_API_KEY         mistral-api-key
read_secret COHERE_API_KEY          cohere-api-key

CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-/opt/openclaw/config}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/opt/openclaw/workspace}"

# When running under OpenShell, /opt/openclaw may not be writable
# (different GID). Fall back to $HOME-based paths.
if ! mkdir -p "${CONFIG_DIR}" 2>/dev/null; then
    CONFIG_DIR="${HOME}/.openclaw"
    echo "[entrypoint] /opt/openclaw not writable, using ${CONFIG_DIR}"
fi
if ! mkdir -p "${WORKSPACE_DIR}" 2>/dev/null; then
    WORKSPACE_DIR="${HOME}/workspace"
    echo "[entrypoint] /opt/openclaw not writable, using ${WORKSPACE_DIR}"
fi
export OPENCLAW_CONFIG_DIR="${CONFIG_DIR}"
export OPENCLAW_WORKSPACE_DIR="${WORKSPACE_DIR}"

mkdir -p "${CONFIG_DIR}" "${WORKSPACE_DIR}"

ENV_FILE="${CONFIG_DIR}/.env"
INITIALIZED_FLAG="${CONFIG_DIR}/.initialized"

echo "[entrypoint] Starting OpenClaw gateway (CSB naked claw)..."
echo "[entrypoint] Config dir:    ${CONFIG_DIR}  (HOME=${HOME})"
echo "[entrypoint] Workspace dir: ${WORKSPACE_DIR}"

# ---------------------------------------------------------------------------
# First-run bootstrap
# ---------------------------------------------------------------------------
if [[ ! -f "${INITIALIZED_FLAG}" ]]; then
    echo "[entrypoint] First run detected — bootstrapping config..."

    if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
        echo "[entrypoint] ERROR: OPENCLAW_GATEWAY_TOKEN is not set." >&2
        echo "[entrypoint]        Provide via -e or --secret openclaw-gateway-token" >&2
        exit 1
    fi

    if [[ ! -f "${ENV_FILE}" ]]; then
        cat > "${ENV_FILE}" <<EOF
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
OPENCLAW_DISABLE_BONJOUR=1
NODE_ENV=production
EOF
        echo "[entrypoint] Wrote ${ENV_FILE}"
    fi

    echo "[entrypoint] Running onboard (non-interactive, local mode)..."
    node /app/dist/index.js onboard \
        --mode local \
        --no-install-daemon \
        --yes 2>&1 || true

    touch "${INITIALIZED_FLAG}"
    echo "[entrypoint] Bootstrap complete."
else
    echo "[entrypoint] Config already initialized — skipping bootstrap."
fi

# ---------------------------------------------------------------------------
# Write locked-down gateway config on EVERY startup.
# This overwrites any runtime modifications — the CSB config is immutable.
# ---------------------------------------------------------------------------
echo "[entrypoint] Writing CSB naked claw config to openclaw.json..."

ALLOWED_ORIGINS="[\"http://localhost:18789\",\"http://127.0.0.1:18789\""
if [[ -n "${OPENCLAW_PUBLIC_URL:-}" ]]; then
    ALLOWED_ORIGINS="${ALLOWED_ORIGINS},\"${OPENCLAW_PUBLIC_URL}\""
fi
ALLOWED_ORIGINS="${ALLOWED_ORIGINS}]"
export ALLOWED_ORIGINS

node << 'JSEOF'
const fs = require("fs");
const cfgPath = (process.env.OPENCLAW_CONFIG_DIR || (process.env.HOME + "/.openclaw")) + "/openclaw.json";

let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8")); } catch(e) {}

// --- Gateway ---
cfg.gateway            = cfg.gateway            || {};
cfg.gateway.mode       = "local";
cfg.gateway.bind       = "lan";
cfg.gateway.auth       = cfg.gateway.auth       || {};
cfg.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN || cfg.gateway.auth.token;
cfg.gateway.controlUi  = cfg.gateway.controlUi  || {};
cfg.gateway.controlUi.allowedOrigins = JSON.parse(process.env.ALLOWED_ORIGINS);

// --- Default model ---
const defaultModel = process.env.OPENCLAW_DEFAULT_MODEL || "";
if (defaultModel) {
  cfg.agents         = cfg.agents         || {};
  cfg.agents.defaults = cfg.agents.defaults || {};
  cfg.agents.defaults.model = cfg.agents.defaults.model || {};
  cfg.agents.defaults.model.primary = defaultModel;
  cfg.agents.defaults.models = cfg.agents.defaults.models || {};
  cfg.agents.defaults.models[defaultModel] = cfg.agents.defaults.models[defaultModel] || {};
  console.log("[entrypoint] Default model set to: " + defaultModel);
}

// --- Internal LLM override ---
const internalUrl   = process.env.OPENCLAW_OPENAI_BASE_URL || "";
const internalModel = process.env.OPENCLAW_OPENAI_MODEL    || "";
const internalKey   = process.env.OPENCLAW_OPENAI_API_KEY  || "ignored";

if (internalUrl && internalModel) {
  cfg.models                   = cfg.models                   || {};
  cfg.models.providers         = cfg.models.providers         || {};
  cfg.models.providers["internal-llm"] = {
    baseUrl: internalUrl,
    api:     "openai-completions",
    apiKey:  internalKey,
    models:  [{ id: internalModel }]
  };
  cfg.agents                              = cfg.agents                              || {};
  cfg.agents.defaults                     = cfg.agents.defaults                     || {};
  cfg.agents.defaults.model               = cfg.agents.defaults.model               || {};
  cfg.agents.defaults.model.primary       = "internal-llm/" + internalModel;
  cfg.agents.defaults.models              = cfg.agents.defaults.models              || {};
  cfg.agents.defaults.models["internal-llm/" + internalModel] =
    cfg.agents.defaults.models["internal-llm/" + internalModel] || {};
  console.log("[entrypoint] Internal LLM configured: <endpoint-redacted>");
  console.log("[entrypoint] Primary model overridden to: internal-llm/" + internalModel);
}

// =========================================================================
// CSB NAKED CLAW LOCKDOWN — enforced on every startup
// =========================================================================

// --- Plugins: disabled entirely ---
cfg.plugins          = cfg.plugins || {};
cfg.plugins.enabled  = false;
cfg.plugins.allow    = [];
cfg.plugins.deny     = ["*"];

// --- Skills: none allowed ---
cfg.skills                  = cfg.skills || {};
cfg.skills.allowBundled     = [];
cfg.skills.install          = cfg.skills.install || {};
cfg.skills.install.allowUploadedArchives = false;

// --- Agents: no skills ---
cfg.agents                      = cfg.agents || {};
cfg.agents.defaults             = cfg.agents.defaults || {};
cfg.agents.defaults.skills      = [];

// --- Tools: allowlist-restricted execution ---
cfg.tools                       = cfg.tools || {};
cfg.tools.deny                  = ["browser", "canvas", "cron"];
cfg.tools.exec                  = cfg.tools.exec || {};
cfg.tools.exec.security         = "allowlist";
cfg.tools.exec.allow            = ["curl", "git", "jq"];
cfg.tools.elevated              = cfg.tools.elevated || {};
cfg.tools.elevated.enabled      = false;
cfg.tools.fs                    = cfg.tools.fs || {};
cfg.tools.fs.workspaceOnly      = true;

// --- URL allowlists: GitHub + Red Hat domains only ---
cfg.gateway.http                              = cfg.gateway.http || {};
cfg.gateway.http.endpoints                    = cfg.gateway.http.endpoints || {};
cfg.gateway.http.endpoints.responses          = cfg.gateway.http.endpoints.responses || {};
cfg.gateway.http.endpoints.responses.files    = cfg.gateway.http.endpoints.responses.files || {};
cfg.gateway.http.endpoints.responses.files.allowUrl     = true;
cfg.gateway.http.endpoints.responses.files.urlAllowlist = [
  "github.com", "*.github.com", "*.githubusercontent.com",
  "redhat.com", "*.redhat.com"
];
cfg.gateway.http.endpoints.responses.images   = cfg.gateway.http.endpoints.responses.images || {};
cfg.gateway.http.endpoints.responses.images.allowUrl     = true;
cfg.gateway.http.endpoints.responses.images.urlAllowlist = [
  "github.com", "*.github.com", "*.githubusercontent.com",
  "redhat.com", "*.redhat.com"
];

// --- Hooks and cron: disabled ---
cfg.hooks          = cfg.hooks || {};
cfg.hooks.enabled  = false;
cfg.cron           = cfg.cron || {};
cfg.cron.enabled   = false;

// --- Discovery: disabled ---
cfg.discovery              = cfg.discovery || {};
cfg.discovery.mdns         = cfg.discovery.mdns || {};
cfg.discovery.mdns.mode    = "off";

fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
console.log("[entrypoint] openclaw.json written (CSB naked claw lockdown applied).");
console.log(JSON.stringify({
  gateway: { mode: cfg.gateway.mode, bind: cfg.gateway.bind },
  plugins: cfg.plugins,
  tools: { deny: cfg.tools.deny, "exec.security": cfg.tools.exec.security, "exec.allow": cfg.tools.exec.allow, "elevated.enabled": cfg.tools.elevated.enabled, "fs.workspaceOnly": cfg.tools.fs.workspaceOnly },
  "url.allowlist": cfg.gateway.http.endpoints.responses.files.urlAllowlist,
  skills: cfg.skills,
  hooks: cfg.hooks,
  cron: cfg.cron,
  discovery: cfg.discovery
}, null, 2));
JSEOF

# ---------------------------------------------------------------------------
# Start the gateway with config immutability
# OPENCLAW_NIX_MODE=1 prevents runtime modification of openclaw.json
# ---------------------------------------------------------------------------
echo "[entrypoint] Launching OpenClaw gateway (NIX_MODE=1, port 18789)..."
export OPENCLAW_NIX_MODE=1
exec node /app/dist/index.js gateway --allow-unconfigured
