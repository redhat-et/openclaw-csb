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
podman volume create openclaw-config
podman volume create openclaw-workspace
```

### 3. Run

```bash
podman run -d --name openclaw-csb \
  -p 18789:18789 \
  -v openclaw-config:/opt/openclaw/config:Z \
  -v openclaw-workspace:/opt/openclaw/workspace:Z \
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
podman exec openclaw-csb mkdir -p /opt/openclaw/workspace/skills/my-skill
podman cp my-skill/SKILL.md openclaw-csb:/opt/openclaw/workspace/skills/my-skill/SKILL.md
```

Skills persist across restarts and upgrades via the `openclaw-workspace` volume.

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
  -v openclaw-config:/opt/openclaw/config:Z \
  -v openclaw-workspace:/opt/openclaw/workspace:Z \
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

## Security Lockdown

The CSB image enforces a hardened configuration on every startup:

| Control | Setting |
|---|---|
| Plugins | Disabled (`plugins.enabled: false`, `deny: ["*"]`) |
| Skills install | ClawHub/marketplace blocked, workspace skills allowed |
| Shell execution | Allowlist only (`bash`, `sh`, `curl`, `git`, `date`) |
| Filesystem | Workspace only (`tools.fs.workspaceOnly: true`) |
| Elevated mode | Disabled |
| Config modification | Blocked (`OPENCLAW_NIX_MODE=1`) |
| Hooks / Cron | Disabled |
| mDNS discovery | Disabled |
| URL allowlist | `github.com`, `*.github.com`, `*.githubusercontent.com`, `redhat.com`, `*.redhat.com` |

The config is rewritten on every container start — runtime modifications are overwritten.

## Policy Overlap: OpenClaw vs OpenShell

The CSB image has two layers of policy enforcement. Some controls overlap — both layers enforce independently, so the most restrictive wins.

| Control | OpenClaw (entrypoint/openclaw.json) | OpenShell (sandbox policy) | Overlap? |
|---|---|---|---|
| **Exec allowlist** | `tools.exec.mode: "allowlist"`, `safeBins: ["bash","sh","curl","git","date"]` | `permissions.process.allow_exec: true` (default allows all) | **Yes** — OpenClaw is more restrictive. OpenShell default permits any exec. |
| **URL allowlist** | `gateway.http.endpoints.responses.files.urlAllowlist` / `images.urlAllowlist` — GitHub + Red Hat domains | `policy update --add-endpoint` / `--add-allow` — per-host:port:method:path | **Yes** — OpenClaw controls what the *gateway HTTP API* fetches on behalf of clients. OpenShell controls what the *agent process* can reach outbound. Different enforcement points. |
| **Network egress** | No control — OpenClaw has no outbound network restriction | `permissions.network.allow` + endpoint rules — controls all outbound at the proxy | **No overlap** — only OpenShell restricts egress. Without OpenShell, the container has full internet access. |
| **Credential protection** | Podman secrets mounted at `/run/secrets/`, read into env vars by entrypoint | Provider placeholder proxy — agent sees `openshell:resolve:env:...`, real key resolved at network boundary | **No overlap** — different mechanisms. OpenShell is strictly superior (agent never holds real key). |
| **Filesystem** | `tools.fs.workspaceOnly: true` — OpenClaw agent restricted to workspace dir | `permissions.filesystem.write: [/sandbox, /tmp]` — OS-level write restriction | **Yes** — both restrict writes. OpenClaw is application-level (agent honors it). OpenShell is OS-level (enforced regardless of agent behavior). |
| **Plugin loading** | `plugins.enabled: false`, `plugins.deny: ["*"]` | No equivalent — OpenShell doesn't know about OpenClaw plugins | **No overlap** — only OpenClaw controls plugin loading. |
| **Config immutability** | `OPENCLAW_NIX_MODE=1` — blocks `config set/patch/unset` | No equivalent — OpenShell doesn't intercept OpenClaw CLI commands | **No overlap** — only OpenClaw controls config mutation. |
| **Skills install** | `skills.install.allowUploadedArchives: false`, NIX_MODE blocks `skills install` | Network policy can block ClawHub domains | **Partial** — OpenClaw blocks at application level, OpenShell can block at network level. |
| **Process execution** | `tools.elevated.enabled: false`, `hooks.enabled: false`, `cron.enabled: false` | `permissions.process.allow_exec` — can deny all exec | **Partial** — OpenClaw disables specific features. OpenShell can blanket-deny all process spawning. |

### Key takeaway

- **OpenClaw config** controls what the *agent* is willing to do (application-level, honesty-based — the agent follows its config)
- **OpenShell policy** controls what the *process* is able to do (OS/network-level, enforcement-based — cannot be bypassed by the agent)
- For defense-in-depth, both layers should agree. A determined attacker who compromises the agent runtime could bypass OpenClaw config but not OpenShell policy.
- The URL allowlists serve different purposes: OpenClaw's controls inbound URL fetching via the gateway API; OpenShell's controls outbound connections from the agent process.

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
podman volume create openclaw-config
podman volume create openclaw-workspace
```

### 4. Launch the sandbox

```bash
openshell sandbox create \
  --name openclaw-csb \
  --from quay.io/redhat-et/openclaw:csb-latest \
  --provider openai \
  --provider github \
  -v openclaw-config:/opt/openclaw/config \
  -v openclaw-workspace:/opt/openclaw/workspace \
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
podman exec openclaw-csb mkdir -p /opt/openclaw/workspace/skills/team-prs
podman cp skills/team-prs/SKILL.md openclaw-csb:/opt/openclaw/workspace/skills/team-prs/SKILL.md

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

Should show: `✓ ready │ team-prs │ ... │ openclaw-workspace`

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
| `curl` executes | `tools.exec.mode: "allowlist"` permits `curl` |
| `bash`, `python`, etc. blocked | Only `safeBins` can execute |
| GitHub API responds | OpenShell network policy allows `api.github.com:443` |
| Credentials isolated | Agent uses placeholder, proxy resolves real token |
| Other endpoints blocked | `curl` to non-approved domains is rejected by proxy |

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
- Skills that use `curl`, `git`, or `date` (the exec allowlist)
- Skills persist across restarts via the workspace volume

**What's blocked:**
- Installing skills from ClawHub / marketplace (`OPENCLAW_NIX_MODE` blocks it)
- Uploading skill archives via the gateway API (`allowUploadedArchives: false`)
- Skills that require tools not on the allowlist (e.g. `python`, `npm`, `node`)
- Bundled skills are disabled (`allowBundled: []`)

Skills are text instructions — they cannot introduce new tool capabilities beyond the exec allowlist. A skill can teach the agent *how* to use `curl` to call an API, but it cannot grant the agent access to `python` or `bash`.

## TODO: RHEL AI Base Image Incompatibilities

The RHEL AI `aipcc-base` image is missing several components required for OpenClaw and OpenShell. The CSB Containerfile currently works around these by copying binaries and shared libraries from builder stages, which is fragile and bypasses RPM dependency management.

### Required RPMs for OpenShell sandboxing

These must be installed in the base image for OpenShell network namespace isolation to function:

| RPM | Provides | Why |
|---|---|---|
| `iproute` | `/usr/sbin/ip` | OpenShell creates network namespaces for credential proxy isolation. Without it, sandboxes fail at startup. |
| `iproute-libs` | `libmnl.so.0` | Dependency of `ip` — netlink message library |
| `elfutils-libelf` | `libelf.so.1` | Dependency of `ip` via libbpf — ELF binary parsing |
| `libbpf` | `libbpf.so.1` | Dependency of `ip` — BPF program loading |

### Required user/group

OpenShell requires a group named `sandbox` in `/etc/group`. The base image has a `sandbox` user (UID 1001) but the group is registered as numeric `1001` instead of named `sandbox`. Either:
- Add `sandbox:x:1001:` to `/etc/group` in the base image, or
- Create the group during image build (current workaround)

### Node.js SQLite version

The base image ships Node 24.18.0 with SQLite 3.46.1, which OpenClaw rejects due to the [WAL-reset database corruption bug](https://sqlite.org/releaselog/3_51_3.html). The CSB image currently overwrites `/usr/bin/node` with the upstream Node.js 24 binary from `docker.io/library/node:24-bookworm-slim` which bundles the corrected SQLite. Options:
- Update the base image's Node.js RPM to a version with SQLite 3.51.3+
- Use UBI 9 Node 22 (already has SQLite 3.51.3)
- Continue overwriting the binary (current workaround)

### Missing package manager

The base image has no `dnf`, `microdnf`, or `yum`. All tools (`curl`, `git`) must be copied as binaries from builder stages. If the base image included a package manager or pre-installed these common tools, the Containerfile would be significantly simpler.

## CI/CD

GitHub Actions builds both architectures on every push and nightly, with Trivy vulnerability scanning and SBOM generation (SPDX + CycloneDX). The image is pinned to OpenClaw release `v2026.7.1`.

| Tag | Description |
|---|---|
| `:csb-latest` | Multi-arch manifest (amd64 + arm64) |
| `:csb-amd64-latest` | Per-arch tag for pinning |
| `:csb-arm64-latest` | Per-arch tag for pinning |
| `:csb-YYYY.MM.DD` | Dated build |
| `:csb-git-<sha>` | Immutable git SHA reference |
