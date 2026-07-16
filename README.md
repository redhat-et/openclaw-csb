# OpenClaw CSB

Secured OpenClaw image for Corporate Standard Build (CSB) laptops. Two-image pipeline: an agentic base image (UBI 10 minimal + OpenShell support) and a CSB OpenClaw layer with locked-down configuration. Deployed via podman or OpenShell.

## Architecture

```
base/Containerfile          → quay.io/redhat-et/openshell:base-latest
    ↓ (used as CSB_BASE_IMAGE)
csb/Containerfile           → quay.io/redhat-et/openclaw:csb-latest
    + csb/entrypoint.sh     (naked claw lockdown config)
    + csb/policy.yaml       (OpenShell deny-by-default network policy)
```

## Quick Start (podman)

### 1. Create secrets

```bash
echo -n "$(openssl rand -hex 32)" | podman secret create openclaw-gateway-token -

# AI provider key (pick one)
echo -n "sk-proj-..." | podman secret create openai-api-key -
```

### 2. Create persistent volumes

```bash
podman volume create openclaw-sandbox-config
podman volume create openclaw-sandbox-workspace
```

### 3. Run

```bash
podman run -d --name openclaw-csb \
  -p 18789:18789 \
  -v openclaw-sandbox-config:/sandbox/.openclaw:Z \
  -v openclaw-sandbox-workspace:/sandbox/workspace:Z \
  --secret openai-api-key \
  --secret openclaw-gateway-token \
  -e OPENCLAW_AI_ENV_VAR=OPENAI_API_KEY \
  -e OPENCLAW_DEFAULT_MODEL=openai/gpt-5.5 \
  -e OPENCLAW_PROVIDERS='{"openai":{"api":"openai-responses","baseUrl":"https://api.openai.com/v1","models":[{"id":"gpt-5.5"}]}}' \
  quay.io/redhat-et/openclaw:csb-latest
```

`OPENCLAW_AI_ENV_VAR` tells the entrypoint which secret contains the AI provider key (e.g. `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`). The image is multi-arch — `csb-latest` resolves to the correct architecture (amd64 or arm64) automatically.

### 4. Connect

Open `http://localhost:18789` and paste your gateway token.

```bash
podman exec openclaw-csb cat /run/secrets/openclaw-gateway-token
```

### Upgrading (podman)

Volumes persist across image upgrades. Skills, conversation history, and device pairing carry over:

```bash
podman rm -f openclaw-csb
podman pull quay.io/redhat-et/openclaw:csb-latest
# Re-run the podman run command from step 3
```

## Running with OpenShell

[OpenShell](https://github.com/NVIDIA/OpenShell) provides credential isolation, network policy enforcement, and sandboxed execution. Credentials never enter the container — the OpenShell proxy resolves placeholder tokens at the network boundary.

### 1. Install OpenShell

```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
openshell gateway list
```

### 2. Create providers

Credentials are stored on the gateway — never inside the sandbox.

```bash
# OpenAI (for LLM)
read -s -p "OpenAI API Key: " OPENAI_API_KEY
export OPENAI_API_KEY
openshell provider create --name openai --type openai --from-existing
unset OPENAI_API_KEY

# GitHub (for API access via curl)
read -s -p "GitHub Token: " GH_TOKEN
export GH_TOKEN
openshell provider create --name github --type github --from-existing
unset GH_TOKEN

# Enable Providers v2 for runtime attach/detach
openshell settings set --global --key providers_v2_enabled --value true
```

### 3. Launch the sandbox

```bash
openshell sandbox create \
  --name openclaw-csb \
  --from quay.io/redhat-et/openclaw:csb-latest \
  --provider openai \
  --provider github \
  --forward 18789 \
  --env OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)" \
  --env OPENCLAW_AI_ENV_VAR=OPENAI_API_KEY \
  --env OPENCLAW_DEFAULT_MODEL=openai/gpt-5.5 \
  --env NODE_ENV=production \
  --env OPENCLAW_PROVIDERS='{"openai":{"api":"openai-responses","baseUrl":"https://api.openai.com/v1","models":[{"id":"gpt-5.5"}]}}' \
  -- /app/entrypoint.sh
```

### 4. Add network policy for API access

The CSB image ships with `network.allow: false` — endpoints must be explicitly approved:

```bash
# OpenAI API
openshell policy update openclaw-csb \
  --add-endpoint api.openai.com:443:read-only:rest:enforce \
  --binary /usr/bin/node --wait

openshell policy update openclaw-csb \
  --add-allow 'api.openai.com:443:POST:/v1/responses' \
  --add-allow 'api.openai.com:443:POST:/v1/chat/completions' \
  --add-allow 'api.openai.com:443:GET:/v1/models' --wait

# GitHub API
openshell policy update openclaw-csb \
  --add-endpoint api.github.com:443:read-only:rest:enforce \
  --binary /usr/bin/curl --wait
```

### 5. Connect

Open `http://localhost:18789` and paste the gateway token.

### Upgrading

Providers persist on the gateway. Volumes persist across image upgrades:

```bash
openshell sandbox delete openclaw-csb
podman pull quay.io/redhat-et/openclaw:csb-latest
# Re-run the sandbox create command from step 3
```

### Adding providers at runtime

```bash
openshell sandbox provider attach openclaw-csb <provider-name>
openshell sandbox provider detach openclaw-csb <provider-name>
```

### How credential isolation works

```
Admin → openshell provider create (stores key on gateway)
  → Sandbox gets placeholder (openshell:resolve:env:...)
    → Agent sends request with placeholder in Authorization header
      → OpenShell proxy swaps placeholder → real key → upstream API
```

## Security: Two-Layer Policy Model

**OpenClaw config** controls what the agent is *willing* to do (application-level).
**OpenShell policy** controls what the process is *able* to do (OS/network-level, cannot be bypassed).

### Layer 1: OpenClaw Config ([`csb/entrypoint.sh`](csb/entrypoint.sh))

Written fresh on every container start. Immutable at runtime (`OPENCLAW_NIX_MODE=1`).

| Control | Setting |
|---|---|
| Plugins | Disabled (`plugins.enabled: false`, `deny: ["*"]`) |
| Skills install | ClawHub/marketplace blocked, workspace skills allowed |
| Tool execution | Full — OpenShell is the enforcement layer (`tools.exec.mode: "full"`) |
| Denied tools | `browser`, `canvas`, `cron`, `web_fetch`, `web_search` |
| Elevated mode | Disabled |
| Filesystem | Workspace only (`tools.fs.workspaceOnly: true`) |
| Config mutation | Blocked (`OPENCLAW_NIX_MODE=1`) |
| Hooks / Cron | Disabled |
| mDNS discovery | Disabled |

### Layer 2: OpenShell Policy ([`csb/policy.yaml`](csb/policy.yaml))

Baked into the image at `/etc/openshell/policy.yaml`. Endpoints added at runtime via `openshell policy update`.

| Control | Setting |
|---|---|
| Network | **Deny by default** (`network.allow: false`) |
| Filesystem writes | `/sandbox` and `/tmp` only |
| Process execution | Allowed (OpenClaw denied tools still blocked at application level) |
| Credential isolation | Agent sees placeholder tokens, proxy resolves real keys |

### Which layer enforces what

| Capability | OpenClaw | OpenShell | Enforced by |
|---|---|---|---|
| Run `curl` | Allowed | Allowed | Both allow |
| Reach `api.github.com` | N/A | Only if endpoint added | **OpenShell** |
| Reach `evil.com` | N/A | **Blocked** (deny by default) | **OpenShell** |
| Real API key visible | Placeholder only | Proxy resolves at boundary | **OpenShell** |
| Install plugins | **Blocked** | N/A | **OpenClaw** |
| Modify config | **Blocked** (NIX_MODE) | N/A | **OpenClaw** |
| Use `web_fetch` | **Blocked** (tools.deny) | N/A | **OpenClaw** |
| Write to `/etc` | **Blocked** (workspaceOnly) | **Blocked** (write: /sandbox, /tmp) | **Both** |

### Without OpenShell (bare podman)

OpenClaw config is the only control. Credentials are in env vars. Network egress is unrestricted. Use podman secrets to avoid credentials in shell history.

### With OpenShell

Network deny-by-default. Credentials never enter the container. The sandbox boundary is the real security perimeter.

## Configuring Model Providers

Providers are configured via JSON file or environment variable — not hardcoded in the image.

### providers.json (recommended)

```json
{
  "openai": {
    "api": "openai-responses",
    "baseUrl": "https://api.openai.com/v1",
    "models": [{ "id": "gpt-5.5", "name": "GPT-5.5" }]
  },
  "ollama": {
    "api": "openai-completions",
    "baseUrl": "http://host.containers.internal:11434/v1",
    "apiKey": "ignored",
    "models": [{ "id": "granite-code:8b", "name": "Granite Code 8B" }]
  }
}
```

Mount into the config directory:

```bash
-v ./providers.json:/sandbox/.openclaw/providers.json:ro,Z
```

Or pass inline as an environment variable:

```bash
-e OPENCLAW_PROVIDERS='{"openai":{"api":"openai-responses","baseUrl":"https://api.openai.com/v1","models":[{"id":"gpt-5.5"}]}}'
```

Change the default model: `-e OPENCLAW_DEFAULT_MODEL=openai/gpt-5.5`

The entrypoint checks for providers in this order:
1. `$OPENCLAW_CONFIG_DIR/providers.json` (volume mount)
2. `/run/secrets/openclaw-providers` (podman secret)
3. `OPENCLAW_PROVIDERS` env var

## Supported Secrets (podman only)

When running with podman (not OpenShell), credentials are passed via podman secrets. With OpenShell, use providers instead — see [Create providers](#2-create-providers).

All secrets are optional except `openclaw-gateway-token`. Mount via `--secret <name>`:

| Secret name | Environment variable | Purpose |
|---|---|---|
| `openclaw-gateway-token` | `OPENCLAW_GATEWAY_TOKEN` | **Required.** Control UI auth |
| `openai-api-key` | `OPENAI_API_KEY` | OpenAI provider |
| `anthropic-api-key` | `ANTHROPIC_API_KEY` | Anthropic provider |
| `google-api-key` | `GOOGLE_API_KEY` | Google provider |
| `xai-api-key` | `XAI_API_KEY` | xAI provider |
| `mistral-api-key` | `MISTRAL_API_KEY` | Mistral provider |
| `cohere-api-key` | `COHERE_API_KEY` | Cohere provider |

## Testing Skills

The repo includes `skills/team-prs` — queries GitHub for recent PRs/issues across a team.

### Load a skill

```bash
# Podman
podman exec openclaw-csb mkdir -p /sandbox/workspace/skills/team-prs
podman cp skills/team-prs/SKILL.md openclaw-csb:/sandbox/workspace/skills/team-prs/SKILL.md

# OpenShell
openshell sandbox exec -n openclaw-csb -- mkdir -p /sandbox/workspace/skills/team-prs
openshell sandbox upload openclaw-csb skills/team-prs/SKILL.md /sandbox/workspace/skills/team-prs/
```

### Verify

```bash
openshell sandbox exec -n openclaw-csb -- node /app/dist/index.js skills list | grep team-prs
```

### Test blocked behavior

Type these in the Control UI to verify the lockdown:

| Prompt | Expected | Layer |
|---|---|---|
| `Search the web for "Red Hat"` | `web_search` unavailable | OpenClaw `tools.deny` |
| `Fetch https://evil.example.com` | `web_fetch` unavailable | OpenClaw `tools.deny` |
| `Run: openclaw config set plugins.enabled true` | `NixModeConfigMutationError` | OpenClaw NIX_MODE |
| `Run: openclaw plugins install slack` | Blocked by NIX_MODE | OpenClaw NIX_MODE |

### Creating skills

```yaml
---
name: my-skill
description: What this skill does.
---
# Instructions for the agent...
```

**Allowed:** workspace skills, `curl`, `git`, `date`, `bash`
**Blocked:** ClawHub installs, uploaded archives, bundled skills, unapproved network endpoints

## TODO: Base Image

The CSB image builds on an agentic base (`base/Containerfile`) from UBI 10 minimal. One remaining workaround:

**Node.js SQLite version** — All UBI 10 Node versions (22.23.1, 24.18.0) ship SQLite 3.46.1 ([WAL corruption bug](https://sqlite.org/releaselog/3_51_3.html)). This causes a non-fatal warning during `pnpm install` postinstall (`could not migrate plugin registry`) and a fatal error at runtime. The CSB Containerfile works around this by overwriting `/usr/bin/node` at runtime with upstream Node 24 from `docker.io/library/node:24-bookworm-slim` which bundles SQLite 3.51.3+. The build-time warning is harmless — the plugin registry migration is not required for the build to succeed. Resolved once UBI ships any Node version with SQLite 3.51.3+.

## CI/CD

GitHub Actions builds base → CSB → manifest for both architectures on every push and nightly. Trivy vulnerability scanning and SBOM generation (SPDX + CycloneDX) on every push.

| Repository | Image | Tags |
|---|---|---|
| `quay.io/redhat-et/openshell` | Agentic base | `:base-latest`, `:base-amd64-latest`, `:base-arm64-latest` |
| `quay.io/redhat-et/openclaw` | CSB OpenClaw | `:csb-latest`, `:csb-amd64-latest`, `:csb-arm64-latest` |

Pinned to OpenClaw release `v2026.7.1`.
