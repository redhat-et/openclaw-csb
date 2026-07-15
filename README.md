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
| Skills install | Blocked (no ClawHub, no uploads) |
| Shell execution | Allowlist only (`curl`, `git`, `jq`) |
| Filesystem | Workspace only (`tools.fs.workspaceOnly: true`) |
| Elevated mode | Disabled |
| Config modification | Blocked (`OPENCLAW_NIX_MODE=1`) |
| Hooks / Cron | Disabled |
| mDNS discovery | Disabled |
| URL allowlist | `github.com`, `*.github.com`, `*.githubusercontent.com`, `redhat.com`, `*.redhat.com` |

The config is rewritten on every container start — runtime modifications are overwritten.

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

Register your API credentials with the gateway. They are stored on the gateway only — never inside the sandbox.

```bash
# OpenAI
read -s -p "OpenAI API Key: " OPENAI_API_KEY
export OPENAI_API_KEY
openshell provider create --name openai --type openai --from-existing
unset OPENAI_API_KEY

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
  -v openclaw-config:/opt/openclaw/config \
  -v openclaw-workspace:/opt/openclaw/workspace \
  -e OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)" \
  --forward 18789
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

### Adding more providers

```bash
# GitHub token (for gh CLI / API access)
read -s -p "GitHub Token: " GH_TOKEN
export GH_TOKEN
openshell provider create --name github --type github --from-existing
unset GH_TOKEN

# Attach to running sandbox
openshell sandbox provider attach openclaw-csb github
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

The base image has no `dnf`, `microdnf`, or `yum`. All tools (`curl`, `git`, `jq`) must be copied as binaries from builder stages. If the base image included a package manager or pre-installed these common tools, the Containerfile would be significantly simpler.

## CI/CD

GitHub Actions builds both architectures on every push and nightly, with Trivy vulnerability scanning and SBOM generation (SPDX + CycloneDX). The image is pinned to OpenClaw release `v2026.7.1`.

| Tag | Description |
|---|---|
| `:csb-latest` | Multi-arch manifest (amd64 + arm64) |
| `:csb-amd64-latest` | Per-arch tag for pinning |
| `:csb-arm64-latest` | Per-arch tag for pinning |
| `:csb-YYYY.MM.DD` | Dated build |
| `:csb-git-<sha>` | Immutable git SHA reference |
