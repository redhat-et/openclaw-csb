#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const configDir = process.env.OPENCLAW_CONFIG_DIR || path.join(process.env.HOME, ".openclaw");
const configPath = path.join(configDir, "openclaw.json");
const envPath = path.join(configDir, ".env");

function requireNonEmptyString(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${name} must be a non-empty string`);
  }
  return value;
}

function parseJson(value, name) {
  try {
    return JSON.parse(value);
  } catch (error) {
    throw new Error(`${name} must contain valid JSON: ${error.message}`);
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validateHttpUrl(value, name, originOnly = false) {
  requireNonEmptyString(value, name);
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`${name} must be an absolute HTTP or HTTPS URL`);
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) {
    throw new Error(`${name} must use HTTP or HTTPS`);
  }
  if (parsed.username || parsed.password) {
    throw new Error(`${name} must not contain credentials`);
  }
  if (parsed.search || parsed.hash) {
    throw new Error(`${name} must not contain a query or fragment`);
  }
  if (originOnly && parsed.pathname !== "/") {
    throw new Error(`${name} must be an origin without a path`);
  }
  return originOnly ? parsed.origin : value;
}

function loadProviders() {
  const providerPaths = [
    path.join(configDir, "providers.json"),
    "/run/secrets/openclaw-providers",
  ];
  let raw = null;
  let source = null;
  for (const candidate of providerPaths) {
    if (fs.existsSync(candidate)) {
      raw = fs.readFileSync(candidate, "utf8");
      source = candidate;
      break;
    }
  }
  if (raw === null && process.env.OPENCLAW_PROVIDERS) {
    raw = process.env.OPENCLAW_PROVIDERS;
    source = "OPENCLAW_PROVIDERS";
  }
  if (raw === null) {
    return {};
  }

  const providers = parseJson(raw, source);
  if (!isPlainObject(providers)) {
    throw new Error("OPENCLAW_PROVIDERS must be a JSON object");
  }

  const cleanProviders = {};
  for (const [name, provider] of Object.entries(providers)) {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) {
      throw new Error(`Provider name '${name}' is invalid`);
    }
    if (!isPlainObject(provider)) {
      throw new Error(`Provider '${name}' must be a JSON object`);
    }
    const api = requireNonEmptyString(provider.api, `Provider '${name}' api`);
    const baseUrl = validateHttpUrl(provider.baseUrl, `Provider '${name}' baseUrl`);
    if (provider.apiKey !== undefined && typeof provider.apiKey !== "string") {
      throw new Error(`Provider '${name}' apiKey must be a string`);
    }
    if (provider.models !== undefined && !Array.isArray(provider.models)) {
      throw new Error(`Provider '${name}' models must be an array`);
    }

    cleanProviders[name] = { api, baseUrl };
    if (provider.apiKey !== undefined) {
      cleanProviders[name].apiKey = provider.apiKey;
    }
  }
  console.log(`[entrypoint] Loaded ${Object.keys(cleanProviders).length} provider(s) from ${source}`);
  return cleanProviders;
}

function loadExistingConfig() {
  if (!fs.existsSync(configPath)) {
    return {};
  }
  const config = parseJson(fs.readFileSync(configPath, "utf8"), configPath);
  if (!isPlainObject(config)) {
    throw new Error(`${configPath} must contain a JSON object`);
  }
  return config;
}

function atomicWrite(destination, contents, mode) {
  const temporary = path.join(
    path.dirname(destination),
    `.${path.basename(destination)}.${process.pid}.${Date.now()}.tmp`,
  );
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, "wx", mode);
    fs.writeFileSync(descriptor, contents, "utf8");
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporary, destination);
    fs.chmodSync(destination, mode);
    const directory = fs.openSync(path.dirname(destination), "r");
    try {
      fs.fsyncSync(directory);
    } finally {
      fs.closeSync(directory);
    }
  } catch (error) {
    if (descriptor !== undefined) {
      fs.closeSync(descriptor);
    }
    try {
      fs.unlinkSync(temporary);
    } catch {
      // Nothing to clean up after a successful rename or failed creation.
    }
    throw error;
  }
}

function removeLegacyTokenFromEnv() {
  if (!fs.existsSync(envPath)) {
    return;
  }
  const original = fs.readFileSync(envPath, "utf8");
  const sanitized = original
    .split(/(?<=\n)/)
    .filter((line) => !/^\s*(?:export\s+)?OPENCLAW_GATEWAY_TOKEN=/.test(line))
    .join("");
  if (sanitized !== original) {
    const existingMode = fs.statSync(envPath).mode & 0o777;
    atomicWrite(envPath, sanitized, existingMode || 0o600);
    console.log(`[entrypoint] Removed legacy gateway token assignment from ${envPath}`);
  }
}

if (typeof process.env.OPENCLAW_GATEWAY_TOKEN !== "string"
    || process.env.OPENCLAW_GATEWAY_TOKEN.trim().length === 0) {
  throw new Error("OPENCLAW_GATEWAY_TOKEN is required on every startup");
}
const gatewayToken = process.env.OPENCLAW_GATEWAY_TOKEN;
const allowedSkills = parseJson(process.env.OPENCLAW_ALLOWED_SKILLS || "[]", "OPENCLAW_ALLOWED_SKILLS");
if (!Array.isArray(allowedSkills) || !allowedSkills.every(
  (name) => typeof name === "string" && name.trim().length > 0,
)) {
  throw new Error("OPENCLAW_ALLOWED_SKILLS must be a JSON array of non-empty strings");
}

const allowedOrigins = ["http://localhost:18789", "http://127.0.0.1:18789"];
if (process.env.OPENCLAW_PUBLIC_URL) {
  allowedOrigins.push(validateHttpUrl(process.env.OPENCLAW_PUBLIC_URL, "OPENCLAW_PUBLIC_URL", true));
}

fs.mkdirSync(configDir, { recursive: true, mode: 0o700 });
const cfg = loadExistingConfig();

cfg.gateway = cfg.gateway || {};
cfg.gateway.mode = "local";
cfg.gateway.bind = "lan";
cfg.gateway.auth = cfg.gateway.auth || {};
cfg.gateway.auth.token = gatewayToken;
cfg.gateway.controlUi = cfg.gateway.controlUi || {};
cfg.gateway.controlUi.allowedOrigins = allowedOrigins;

cfg.models = cfg.models || {};
cfg.models.providers = loadProviders();

const defaultModel = process.env.OPENCLAW_DEFAULT_MODEL || "";
if (defaultModel) {
  cfg.agents = cfg.agents || {};
  cfg.agents.defaults = cfg.agents.defaults || {};
  cfg.agents.defaults.model = cfg.agents.defaults.model || {};
  cfg.agents.defaults.model.primary = defaultModel;
  cfg.agents.defaults.models = cfg.agents.defaults.models || {};
  cfg.agents.defaults.models[defaultModel] = cfg.agents.defaults.models[defaultModel] || {};
}

cfg.plugins = cfg.plugins || {};
cfg.plugins.enabled = false;
cfg.plugins.allow = [];
cfg.plugins.deny = [];

cfg.skills = cfg.skills || {};
cfg.skills.allowBundled = [];
cfg.skills.install = cfg.skills.install || {};
cfg.skills.install.allowUploadedArchives = false;

cfg.agents = cfg.agents || {};
cfg.agents.defaults = cfg.agents.defaults || {};
cfg.agents.defaults.skills = allowedSkills;

cfg.security = cfg.security || {};
cfg.security.installPolicy = {
  enabled: true,
  targets: ["skill", "plugin"],
  exec: {
    source: "exec",
    command: "/usr/local/bin/openclaw-install-policy",
    timeoutMs: 10000,
    noOutputTimeoutMs: 10000,
    maxOutputBytes: 4096,
    trustedDirs: ["/usr/local/bin"],
  },
};

cfg.tools = cfg.tools || {};
cfg.tools.deny = ["browser", "canvas", "cron", "web_fetch", "web_search"];
cfg.tools.exec = cfg.tools.exec || {};
cfg.tools.exec.mode = "ask";
cfg.tools.elevated = cfg.tools.elevated || {};
cfg.tools.elevated.enabled = false;
cfg.tools.fs = cfg.tools.fs || {};
cfg.tools.fs.workspaceOnly = true;

cfg.gateway.http = cfg.gateway.http || {};
cfg.gateway.http.endpoints = cfg.gateway.http.endpoints || {};
cfg.gateway.http.endpoints.responses = cfg.gateway.http.endpoints.responses || {};
cfg.gateway.http.endpoints.responses.files = cfg.gateway.http.endpoints.responses.files || {};
cfg.gateway.http.endpoints.responses.files.allowUrl = true;
cfg.gateway.http.endpoints.responses.files.urlAllowlist = [
  "github.com", "*.github.com", "*.githubusercontent.com", "redhat.com", "*.redhat.com",
];
cfg.gateway.http.endpoints.responses.images = cfg.gateway.http.endpoints.responses.images || {};
cfg.gateway.http.endpoints.responses.images.allowUrl = true;
cfg.gateway.http.endpoints.responses.images.urlAllowlist = [
  "github.com", "*.github.com", "*.githubusercontent.com", "redhat.com", "*.redhat.com",
];

cfg.hooks = cfg.hooks || {};
cfg.hooks.enabled = false;
cfg.cron = cfg.cron || {};
cfg.cron.enabled = false;
cfg.discovery = cfg.discovery || {};
cfg.discovery.mdns = cfg.discovery.mdns || {};
cfg.discovery.mdns.mode = "off";

atomicWrite(configPath, `${JSON.stringify(cfg, null, 2)}\n`, 0o600);
removeLegacyTokenFromEnv();
console.log(`[entrypoint] ${configPath} written atomically (CSB policy applied, mode 0600).`);
console.log(JSON.stringify({
  gateway: { mode: cfg.gateway.mode, bind: cfg.gateway.bind },
  plugins: cfg.plugins,
  agents: { skills: cfg.agents.defaults.skills },
  security: { installPolicy: cfg.security.installPolicy },
  tools: {
    deny: cfg.tools.deny,
    "exec.mode": cfg.tools.exec.mode,
    "elevated.enabled": cfg.tools.elevated.enabled,
    "fs.workspaceOnly": cfg.tools.fs.workspaceOnly,
  },
  "url.allowlist": cfg.gateway.http.endpoints.responses.files.urlAllowlist,
  skills: cfg.skills,
  hooks: cfg.hooks,
  cron: cfg.cron,
  discovery: cfg.discovery,
}, null, 2));
