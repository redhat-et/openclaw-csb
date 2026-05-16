// =============================================================================
// OpenClaw on OpenShift — Node.js Entrypoint
// File: entrypoint.js
//
// Replaces entrypoint.sh for the Project Hummingbird distroless runtime.
// Distroless images have no shell, so the entrypoint must be a Node.js
// script invoked as: ENTRYPOINT ["node", "/app/entrypoint.js"]
//
// Responsibilities:
//   1. Ensure config and workspace directories exist
//   2. Bootstrap config on first run (write .env, run onboard)
//   3. Write openclaw.json on every start with gateway mode, bind, auth,
//      allowedOrigins, and default model — idempotent, always up to date
//   4. Apply channel configuration from ConfigMap if present
//   5. Spawn the gateway process and forward signals (SIGTERM/SIGINT)
//      so Kubernetes pod termination works correctly
//
// Environment variables (injected by OpenShift Secret / Deployment):
//   OPENCLAW_GATEWAY_TOKEN   — shared secret for the Control UI
//   OPENCLAW_CONFIG_DIR      — config PVC mount (/opt/openclaw/.openclaw)
//   OPENCLAW_WORKSPACE_DIR   — workspace PVC mount (/opt/openclaw/workspace)
//   OPENCLAW_PUBLIC_URL      — Route HTTPS URL added to allowedOrigins
//   OPENCLAW_DEFAULT_MODEL   — e.g. "anthropic/claude-sonnet-4-6"
//   OPENCLAW_CHANNEL_CONFIG_PATH — path to channels-config.json ConfigMap
// =============================================================================

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { join } from "node:path";

const APP            = "/app/dist/index.js";
const CONFIG_DIR     = process.env.OPENCLAW_CONFIG_DIR     || "/opt/openclaw/.openclaw";
const WORKSPACE_DIR  = process.env.OPENCLAW_WORKSPACE_DIR  || "/opt/openclaw/workspace";
const CONFIG_FILE    = join(CONFIG_DIR, "openclaw.json");
const ENV_FILE       = join(CONFIG_DIR, ".env");
const INIT_FLAG      = join(CONFIG_DIR, ".initialized");

const log  = (msg) => process.stdout.write(`[entrypoint] ${msg}\n`);
const warn = (msg) => process.stderr.write(`[entrypoint] WARNING: ${msg}\n`);
const die  = (msg) => { process.stderr.write(`[entrypoint] ERROR: ${msg}\n`); process.exit(1); };

// ---------------------------------------------------------------------------
// 1. Ensure directories exist
// ---------------------------------------------------------------------------
log("Starting OpenClaw gateway...");
log(`Config dir    : ${CONFIG_DIR}  (HOME=${process.env.HOME})`);
log(`Workspace dir : ${WORKSPACE_DIR}`);

mkdirSync(CONFIG_DIR,    { recursive: true });
mkdirSync(WORKSPACE_DIR, { recursive: true });

// ---------------------------------------------------------------------------
// 2. First-run bootstrap
// ---------------------------------------------------------------------------
if (!existsSync(INIT_FLAG)) {
  log("First run detected — bootstrapping config...");

  const token = process.env.OPENCLAW_GATEWAY_TOKEN;
  if (!token) {
    die("OPENCLAW_GATEWAY_TOKEN is not set. Generate one and store it in your OpenShift Secret.");
  }

  // Write minimal .env so the gateway finds its token on restart
  if (!existsSync(ENV_FILE)) {
    writeFileSync(ENV_FILE, [
      "# OpenClaw runtime environment — written by entrypoint.js on first run",
      `OPENCLAW_GATEWAY_TOKEN=${token}`,
      "OPENCLAW_DISABLE_BONJOUR=1",
      "NODE_ENV=production",
      "",
    ].join("\n"));
    log(`Wrote ${ENV_FILE}`);
  }

  // Run non-interactive onboard (--yes suppresses interactive prompts where
  // supported; API keys are picked up from env vars injected by the Secret)
  log("Running onboard (non-interactive, local mode)...");
  spawnSync("node", [APP, "onboard", "--mode", "local", "--no-install-daemon", "--yes"], {
    stdio: "inherit",
  });

  writeFileSync(INIT_FLAG, "");
  log("First-run bootstrap complete.");
} else {
  log("Config already initialized — skipping bootstrap.");
}

// ---------------------------------------------------------------------------
// 3. Write gateway config on every startup (idempotent)
//
// We write openclaw.json directly rather than using `openclaw config set`
// because config set requires the gateway to already be running — a
// chicken-and-egg problem. Writing the JSON file beforehand avoids this.
// The gateway reads the file at startup before accepting any connections.
// ---------------------------------------------------------------------------
log("Writing gateway config to openclaw.json...");

const allowedOrigins = [
  "http://localhost:18789",
  "http://127.0.0.1:18789",
];
const publicUrl = process.env.OPENCLAW_PUBLIC_URL || "";
if (publicUrl) {
  allowedOrigins.push(publicUrl);
  log(`Including ${publicUrl} in controlUi.allowedOrigins`);
}

let cfg = {};
try {
  cfg = JSON.parse(readFileSync(CONFIG_FILE, "utf8"));
} catch {
  // First run or missing file — start fresh
}

// Gateway settings
cfg.gateway                          = cfg.gateway                          || {};
cfg.gateway.mode                     = "local";
cfg.gateway.bind                     = "lan";          // listen on 0.0.0.0 — required for OpenShift router
cfg.gateway.auth                     = cfg.gateway.auth                     || {};
cfg.gateway.auth.token               = process.env.OPENCLAW_GATEWAY_TOKEN   || cfg.gateway.auth.token;
cfg.gateway.controlUi                = cfg.gateway.controlUi                || {};
cfg.gateway.controlUi.allowedOrigins = allowedOrigins;

// Agent default model (from OPENCLAW_DEFAULT_MODEL env var)
const defaultModel = process.env.OPENCLAW_DEFAULT_MODEL || "";
if (defaultModel) {
  cfg.agents                              = cfg.agents                              || {};
  cfg.agents.defaults                     = cfg.agents.defaults                     || {};
  cfg.agents.defaults.model               = cfg.agents.defaults.model               || {};
  cfg.agents.defaults.model.primary       = defaultModel;
  cfg.agents.defaults.models              = cfg.agents.defaults.models              || {};
  cfg.agents.defaults.models[defaultModel] = cfg.agents.defaults.models[defaultModel] || {};
  log(`Default model set to: ${defaultModel}`);
}

writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2));
log("openclaw.json written OK.");

// ---------------------------------------------------------------------------
// 4. Apply channel configuration (idempotent on every start)
//
// The channel ConfigMap is mounted at OPENCLAW_CHANNEL_CONFIG_PATH.
// It contains channels.* config with ${ENV_VAR} placeholders that OpenClaw
// resolves at runtime from the injected Secret env vars.
// ---------------------------------------------------------------------------
const channelConfigPath = process.env.OPENCLAW_CHANNEL_CONFIG_PATH || "";
if (channelConfigPath && existsSync(channelConfigPath)) {
  log(`Applying channel configuration from ${channelConfigPath}...`);
  try {
    const channelCfg = JSON.parse(readFileSync(channelConfigPath, "utf8"));
    const batchJson  = Object.entries(channelCfg.channels || {}).map(([id, val]) => ({
      path:  `channels.${id}`,
      value: val,
    }));

    if (batchJson.length > 0) {
      const result = spawnSync(
        "node",
        [APP, "config", "set", "--batch-json", JSON.stringify(batchJson)],
        { stdio: "inherit" }
      );
      if (result.status === 0) {
        log("Channel config applied.");
      } else {
        warn("channel config set returned non-zero — check config syntax.");
      }
    } else {
      log("No channel entries found in config file — skipping.");
    }
  } catch (err) {
    warn(`Could not apply channel config: ${err.message}`);
  }
} else {
  log("No channel config path set — running gateway-only (no messaging channels).");
}

// ---------------------------------------------------------------------------
// 5. Launch the gateway
//
// We use spawn() with stdio: "inherit" and forward SIGTERM/SIGINT so
// Kubernetes/OpenShift pod termination signals reach the gateway process.
// Without signal forwarding, pods take the full terminationGracePeriod to
// stop instead of shutting down cleanly.
//
// spawn() is used instead of execFileSync() or child_process.exec() because
// we need the parent process to stay alive to handle signals — the gateway
// process is the child, and we proxy its exit code.
// ---------------------------------------------------------------------------
log("Launching OpenClaw gateway on port 18789...");

const gateway = spawn("node", [APP, "gateway", "--allow-unconfigured"], {
  stdio: "inherit",
});

// Signal forwarding — critical for clean Kubernetes pod shutdown
process.on("SIGTERM", () => {
  log("Received SIGTERM — forwarding to gateway...");
  gateway.kill("SIGTERM");
});

process.on("SIGINT", () => {
  log("Received SIGINT — forwarding to gateway...");
  gateway.kill("SIGINT");
});

gateway.on("error", (err) => {
  warn(`Failed to start gateway: ${err.message}`);
  process.exit(1);
});

gateway.on("exit", (code, signal) => {
  log(`Gateway exited — code=${code ?? "null"} signal=${signal ?? "null"}`);
  process.exit(code ?? 0);
});
