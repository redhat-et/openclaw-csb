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
