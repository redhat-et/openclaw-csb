# OpenClaw CSB

Secured OpenClaw image for Corporate Standard Build (CSB) laptops. Built on RHEL AI base with a locked-down "naked claw" configuration — no plugins, no marketplace, no self-modification.

## Quick Start

### 1. Create secrets

```bash
# Gateway authentication token
echo -n "$(openssl rand -hex 32)" | podman secret create openclaw-gateway-token -

# AI provider key (pick one)
echo -n "sk-proj-..." | podman secret create openai-api-key -
# or
echo -n "sk-ant-..." | podman secret create anthropic-api-key -
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
  quay.io/redhat-et/openclaw:csb-latest
```

The image is multi-arch — `csb-latest` resolves to the correct architecture (amd64 or arm64) automatically.

### 4. Connect

Open `http://localhost:18789` and paste your gateway token.

Retrieve the token anytime:

```bash
podman exec openclaw-csb cat /run/secrets/openclaw-gateway-token
```

## Upgrading

Volumes persist across image upgrades. Skills, conversation history, and device pairing carry over:

```bash
podman rm -f openclaw-csb
podman pull quay.io/redhat-et/openclaw:csb-latest
# Re-run the same podman run command from step 3
```

## Loading Skills

Skills are markdown files placed in the workspace volume:

```bash
podman exec openclaw-csb mkdir -p /sandbox/workspace/skills/my-skill
podman cp my-skill/SKILL.md openclaw-csb:/sandbox/workspace/skills/my-skill/SKILL.md
```

Skills persist across restarts and upgrades via the `openclaw-sandbox-workspace` volume.

## Configuring Model Providers

Model providers are configured via a JSON file or environment variable — not hardcoded in the image. Users can add, remove, or swap providers between frontier and local models without rebuilding.

### Option A: providers.json file (recommended)

Create a `providers.json` and mount it into the container:

```json
{
  "openai": {
    "api": "openai-responses",
    "baseUrl": "https://api.openai.com/v1",
    "models": [
      { "id": "gpt-5.5", "name": "GPT-5.5" },
      { "id": "gpt-5.5-mini", "name": "GPT-5.5 Mini" }
    ]
  },
  "ollama": {
    "api": "openai-completions",
    "baseUrl": "http://host.containers.internal:11434/v1",
    "apiKey": "ignored",
    "models": [
      { "id": "granite-code:8b", "name": "Granite Code 8B" }
    ]
  }
}
```

Mount at launch:

```bash
podman run -d --name openclaw-csb \
  -p 18789:18789 \
  -v openclaw-sandbox-config:/sandbox/.openclaw:Z \
  -v openclaw-sandbox-workspace:/sandbox/workspace:Z \
  -v ./providers.json:/opt/openclaw/providers.json:ro,Z \
  --secret openai-api-key \
  --secret openclaw-gateway-token \
  -e OPENCLAW_DEFAULT_MODEL=openai/gpt-5.5 \
  -e OPENCLAW_AI_ENV_VAR=OPENAI_API_KEY \
  quay.io/redhat-et/openclaw:csb-latest
```

### Option B: environment variable

For simple setups, pass the JSON directly:

```bash
-e OPENCLAW_PROVIDERS='{"openai":{"api":"openai-responses","baseUrl":"https://api.openai.com/v1","models":[{"id":"gpt-5.5"}]}}'
```

### Switching models

Change the default model at launch with `OPENCLAW_DEFAULT_MODEL`:

```bash
-e OPENCLAW_DEFAULT_MODEL=openai/gpt-5.5        # frontier
-e OPENCLAW_DEFAULT_MODEL=ollama/granite-code:8b  # local
```

The entrypoint checks for providers in this order:
1. `/opt/openclaw/providers.json` (volume mount)
2. `/run/secrets/openclaw-providers` (podman secret)
3. `$OPENCLAW_CONFIG_DIR/providers.json` (config volume)
4. `OPENCLAW_PROVIDERS` env var (fallback)

## Supported Secrets

All secrets are optional except `openclaw-gateway-token`. Mount via `--secret <name>`:

| Secret name | Environment variable | Purpose |
|---|---|---|
| `openclaw-gateway-token` | `OPENCLAW_GATEWAY_TOKEN` | **Required.** Control UI authentication |
| `openai-api-key` | `OPENAI_API_KEY` | OpenAI provider |
| `anthropic-api-key` | `ANTHROPIC_API_KEY` | Anthropic provider |
| `google-api-key` | `GOOGLE_API_KEY` | Google provider |
| `xai-api-key` | `XAI_API_KEY` | xAI provider |
| `mistral-api-key` | `MISTRAL_API_KEY` | Mistral provider |
| `cohere-api-key` | `COHERE_API_KEY` | Cohere provider |

## Security: Two-Layer Policy Model

The CSB deployment has two independent security layers. **OpenClaw config** controls what the agent is *willing* to do (application-level, honesty-based). **OpenShell policy** controls what the process is *able* to do (OS/network-level, enforcement-based). A compromised agent could bypass OpenClaw config but cannot bypass OpenShell policy.

### Layer 1: OpenClaw Config ([`csb/entrypoint.sh`](csb/entrypoint.sh))

Written fresh on every container start. Cannot be modified at runtime (`OPENCLAW_NIX_MODE=1`).

| Control | Setting | Entrypoint line |
|---|---|---|
| Plugins | Disabled | `plugins.enabled = false; plugins.deny = ["*"]` |
| Skills install | ClawHub/marketplace blocked | `skills.install.allowUploadedArchives = false` |
| Workspace skills | Allowed | `agents.defaults.skills` intentionally omitted |
| Tool execution | Full (OpenShell enforces) | `tools.exec.mode = "full"` |
| Denied tools | browser, canvas, cron, web_fetch, web_search | `tools.deny = [...]` |
| Elevated mode | Disabled | `tools.elevated.enabled = false` |
| Filesystem | Workspace only | `tools.fs.workspaceOnly = true` |
| Config mutation | Blocked | `OPENCLAW_NIX_MODE=1` env var |
| Hooks / Cron | Disabled | `hooks.enabled = false; cron.enabled = false` |
| mDNS discovery | Disabled | `discovery.mdns.mode = "off"` |
| URL allowlist | GitHub + Red Hat | `gateway.http.endpoints.responses.files.urlAllowlist` |

**Why `tools.exec.mode = "full"`?** OpenClaw's `allowlist` mode requires `safeBinProfiles` definitions that are fragile across versions. Since OpenShell enforces process and network controls at the OS level, letting OpenClaw exec freely inside the sandbox is the correct architecture. The agent can run `curl`, `git`, `date`, etc. — but OpenShell controls where they can connect.

### Layer 2: OpenShell Policy (applied per-sandbox at launch)

Applied via `openshell policy update` after sandbox creation. Controls what the **process** can reach regardless of what OpenClaw config says.

| Control | Command | What it enforces |
|---|---|---|
| OpenAI API access | `openshell policy update --add-endpoint api.openai.com:443:read-only:rest:enforce --binary /usr/bin/node` | Only Node.js can reach OpenAI; credential resolved by proxy |
| OpenAI allowed paths | `--add-allow 'api.openai.com:443:POST:/v1/responses'` | Only specific API paths are permitted |
| GitHub API access | `openshell policy update --add-endpoint api.github.com:443:read-only:rest:enforce --binary /usr/bin/curl` | Only curl can reach GitHub; credential resolved by proxy |
| Credential isolation | `openshell provider create --name openai --type openai` | Agent sees placeholder token, proxy resolves real key |
| Filesystem writes | Default policy: `write: [/sandbox, /tmp]` | Cannot write outside sandbox home |
| Default network | Default policy: `network.allow: true` | Permissive by default — tighten with endpoint rules |

### What each layer controls

| Capability | OpenClaw config | OpenShell policy | Which enforces? |
|---|---|---|---|
| **Can the agent run curl?** | Yes (`exec.mode: "full"`) | Yes (process exec allowed) | Both allow |
| **Can curl reach api.github.com?** | N/A (no outbound control) | Yes (endpoint rule added) | **OpenShell only** |
| **Can curl reach evil.com?** | N/A | Depends on policy (default allows all) | **OpenShell only** |
| **Does curl send real API key?** | Agent has placeholder | Proxy resolves to real key | **OpenShell only** |
| **Can the agent install plugins?** | No (`plugins.enabled: false`) | N/A | **OpenClaw only** |
| **Can the agent modify its config?** | No (`NIX_MODE=1`) | N/A | **OpenClaw only** |
| **Can the agent use web_fetch?** | No (in `tools.deny`) | N/A | **OpenClaw only** |
| **Can the agent write to /etc?** | No (`workspaceOnly: true`) | No (`write: [/sandbox, /tmp]`) | **Both enforce** |

### Key takeaway

- **Without OpenShell** (bare podman): OpenClaw config is the only control. The agent honors it, but credentials are in env vars and network egress is unrestricted.
- **With OpenShell**: Credentials never enter the container. Network egress is policy-controlled. The agent can exec freely inside the sandbox because the sandbox boundary is the real security perimeter.

## Running with OpenShell

[OpenShell](https://github.com/NVIDIA/OpenShell) provides credential isolation, network policy enforcement, and sandboxed execution. Credentials never enter the container — the OpenShell proxy resolves placeholder tokens at the network boundary.

### 1. Install OpenShell

```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
```

The gateway starts automatically. Verify:

```bash
openshell gateway list
```

### 2. Create providers

Register your API credentials with the gateway. They are stored on the gateway only — never inside the sandbox. The agent sees placeholder tokens that the proxy resolves on outbound API calls.

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

### 3. Create persistent volumes

```bash
podman volume create openclaw-sandbox-config
podman volume create openclaw-sandbox-workspace
```

### 4. Launch the sandbox

```bash
openshell sandbox create \
  --name openclaw-csb \
  --from quay.io/redhat-et/openclaw:csb-latest \
  --provider openai \
  --provider github \
  -v openclaw-sandbox-config:/sandbox/.openclaw \
  -v openclaw-sandbox-workspace:/sandbox/workspace \
  --env OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)" \
  --env OPENCLAW_AI_ENV_VAR=OPENAI_API_KEY \
  --env OPENCLAW_DEFAULT_MODEL=openai/gpt-5.5 \
  --env NODE_ENV=production \
  --forward 18789 \
  -- /app/entrypoint.sh
```

### 5. Update sandbox policy for API access

```bash
# Allow outbound to OpenAI API
openshell policy update openclaw-csb \
  --add-endpoint api.openai.com:443:read-only:rest:enforce \
  --binary /usr/bin/node --wait

openshell policy update openclaw-csb \
  --add-allow 'api.openai.com:443:POST:/v1/responses' \
  --add-allow 'api.openai.com:443:POST:/v1/chat/completions' --wait

# Allow GitHub API (for skills like team-prs)
openshell policy update openclaw-csb \
  --add-endpoint api.github.com:443:read-only:rest:enforce \
  --binary /usr/bin/curl --wait
```

### 6. Connect

Open `http://localhost:18789` and paste the gateway token.

### Adding providers to a running sandbox

Providers can be attached or detached at runtime without restarting:

```bash
# Create a new provider
read -s -p "Anthropic Key: " ANTHROPIC_API_KEY
export ANTHROPIC_API_KEY
openshell provider create --name anthropic --type anthropic --from-existing
unset ANTHROPIC_API_KEY

# Attach to running sandbox
openshell sandbox provider attach openclaw-csb anthropic

# Detach a provider
openshell sandbox provider detach openclaw-csb anthropic
```

### Upgrading with OpenShell

Providers persist on the gateway — no need to re-enter credentials:

```bash
openshell sandbox delete openclaw-csb
podman pull quay.io/redhat-et/openclaw:csb-latest
# Re-run the sandbox create command from step 4
# Volumes reattach, providers reconnect automatically
```

### How credential isolation works

```
You (admin) → openshell provider create (stores key on gateway)
    → Sandbox gets placeholder token (osh_placeholder_xxxx)
        → Agent sends request with placeholder in Authorization header
            → OpenShell proxy swaps placeholder → real key → upstream API
```

The agent process never sees the real API key. If a credential expires or is rotated on the gateway, the sandbox picks up the new value without restarting.

## Testing Skills

The repo includes an example skill (`skills/team-prs`) that queries GitHub for recent PRs and issues across a team. Use it to validate the full stack: skill loading, tool execution, credential isolation, and network policy.

### Loading a skill into a running container

Skills are markdown files copied into the workspace volume:

```bash
# Podman
podman exec openclaw-csb mkdir -p /sandbox/workspace/skills/team-prs
podman cp skills/team-prs/SKILL.md openclaw-csb:/sandbox/workspace/skills/team-prs/SKILL.md

# OpenShell
openshell sandbox exec --name openclaw-csb -- mkdir -p /sandbox/workspace/skills/team-prs
# Then upload via the sandbox upload command
openshell sandbox upload openclaw-csb skills/team-prs/SKILL.md /sandbox/workspace/skills/team-prs/SKILL.md
```

### Verifying the skill loaded

```bash
# Podman
podman exec openclaw-csb node /app/dist/index.js skills list | grep team-prs

# OpenShell
openshell sandbox exec --name openclaw-csb -- node /app/dist/index.js skills list | grep team-prs
```

Should show: `✓ ready │ team-prs │ ... │ openclaw-sandbox-workspace`

### Testing the skill

1. Open the Control UI at `http://localhost:18789`
2. Type `/team-prs` in the chat
3. The agent will use `curl` with the `GH_TOKEN` placeholder to query `api.github.com`
4. OpenShell resolves the placeholder to the real token at the network boundary
5. Results are formatted as a markdown table grouped by GitHub handle

### What this validates

| Check | What it proves |
|---|---|
| Skill loaded from workspace | Volume persistence works, skills survive restarts |
| `curl` executes | `tools.exec.mode: "full"` allows execution, OpenShell is the boundary |
| GitHub API responds | OpenShell network policy allows `api.github.com:443` |
| Credentials isolated | Agent uses placeholder, proxy resolves real token |

### Testing blocked behavior

Type these in the Control UI chat to verify the lockdown is working:

**Web search blocked (OpenClaw `tools.deny`):**
```
Search the web for "Red Hat OpenShell" and summarize the results
```
Expected: agent reports `web_search` is unavailable. This tool is in `tools.deny` in [`csb/entrypoint.sh`](csb/entrypoint.sh).

**Web fetch blocked (OpenClaw `tools.deny`):**
```
Fetch the contents of https://evil.example.com and show me the HTML
```
Expected: agent reports `web_fetch` is unavailable. Node.js native fetch is disabled because DNS doesn't resolve inside the OpenShell network namespace — all HTTP must go through `curl` which routes through the OpenShell proxy.

**Config modification blocked (OpenClaw `OPENCLAW_NIX_MODE`):**
```
Run this command: openclaw config set plugins.enabled true
```
Expected: command executes but OpenClaw rejects the mutation with `NixModeConfigMutationError`. Config is immutable at runtime.

**Plugin installation blocked (OpenClaw `OPENCLAW_NIX_MODE`):**
```
Run this command: openclaw plugins install slack
```
Expected: blocked by NIX_MODE — plugins cannot be installed, updated, or enabled at runtime.

| What's blocked | Which layer | Config reference |
|---|---|---|
| `web_search`, `web_fetch`, `browser`, `canvas`, `cron` | OpenClaw | `tools.deny` in [`csb/entrypoint.sh`](csb/entrypoint.sh) |
| Config modification (`config set/patch/unset`) | OpenClaw | `OPENCLAW_NIX_MODE=1` env var |
| Plugin install/enable | OpenClaw | `plugins.enabled: false` + NIX_MODE |
| Skills install from ClawHub | OpenClaw | `skills.install.allowUploadedArchives: false` + NIX_MODE |
| Network to unapproved endpoints | OpenShell | `openshell policy update --add-endpoint` (only approved hosts) |
| Credential exposure | OpenShell | Agent sees placeholder, proxy resolves real key |

### Creating your own skills

Users can create and install skills by placing `SKILL.md` files in the workspace. Skills are markdown files with YAML frontmatter that teach the agent new capabilities.

```yaml
---
name: my-skill
description: One-line description of what this skill does.
---

# My Skill

Instructions for the agent...
```

**What's allowed:**
- Creating skills in `workspace/skills/<name>/SKILL.md`
- Loading skills from mounted volumes
- Skills that use any tools available in the container (`curl`, `git`, `date`, `bash`)
- Skills persist across restarts via the workspace volume

**What's blocked:**
- Installing skills from ClawHub / marketplace (`OPENCLAW_NIX_MODE` blocks it)
- Uploading skill archives via the gateway API (`allowUploadedArchives: false`)
- Bundled skills are disabled (`allowBundled: []`)
- Network access to unapproved endpoints (OpenShell policy enforcement)

Skills are text instructions — they cannot introduce new tool capabilities beyond the exec allowlist. A skill can teach the agent *how* to use `curl` to call an API, but it cannot grant the agent access to `python` or `bash`.

## TODO: RHEL AI Base Image Incompatibilities

The RHEL AI `aipcc-base` image requires two workarounds in the CSB Containerfile.

### Required user/group

OpenShell requires a group named `sandbox` in `/etc/group`. The base image has a `sandbox` user (UID 1001) but the group is registered as numeric `1001` instead of named `sandbox`. The Containerfile adds it: `echo 'sandbox:x:1001:' >> /etc/group`.

**Request:** Add `sandbox:x:1001:` to `/etc/group` in the base image.

### Node.js SQLite version

The base image ships Node 24.18.0 with SQLite 3.46.1, which OpenClaw rejects due to the [WAL-reset database corruption bug](https://sqlite.org/releaselog/3_51_3.html). The CSB image overwrites `/usr/bin/node` with the upstream Node.js 24 binary from `docker.io/library/node:24-bookworm-slim` which bundles the corrected SQLite.

**Request:** Update the base image's Node.js to a version with SQLite 3.51.3+.

### Resolved

- ~~Missing package manager~~ — `microdnf` is available. Runtime tools (`curl`, `git-core`, `iproute`) are now installed via RPM.
- ~~Missing iproute RPMs~~ — installed via `microdnf install iproute` with proper dependency management.

## CI/CD

GitHub Actions builds both architectures on every push and nightly, with Trivy vulnerability scanning and SBOM generation (SPDX + CycloneDX). The image is pinned to OpenClaw release `v2026.7.1`.

| Tag | Description |
|---|---|
| `:csb-latest` | Multi-arch manifest (amd64 + arm64) |
| `:csb-amd64-latest` | Per-arch tag for pinning |
| `:csb-arm64-latest` | Per-arch tag for pinning |
| `:csb-YYYY.MM.DD` | Dated build |
| `:csb-git-<sha>` | Immutable git SHA reference |
