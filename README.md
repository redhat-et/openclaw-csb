<div align="center">
  <img src=".github/logo.svg" width="640" alt="OpenClaw on OpenShift"/>

  <br/><br/>

  [![Build & Push](https://github.com/ryannix123/openclaw-on-openshift/actions/workflows/build.yml/badge.svg)](https://github.com/ryannix123/openclaw-on-openshift/actions/workflows/build.yml)
  [![Base Image](https://img.shields.io/badge/base-UBI%2010-EE0000?logo=redhat&logoColor=white)](https://catalog.redhat.com/software/containers/ubi10/nodejs-22)
  [![Platform](https://img.shields.io/badge/platform-OpenShift-EE0000?logo=redhatopenshift&logoColor=white)](https://developers.redhat.com/developer-sandbox)
  [![Deploy](https://img.shields.io/badge/deploy-Ansible-EE0000?logo=ansible&logoColor=white)](https://docs.ansible.com/)
  [![Runtime](https://img.shields.io/badge/runtime-Node.js%2022-339933?logo=node.js&logoColor=white)](https://nodejs.org/)
  [![Registry](https://img.shields.io/badge/registry-Quay.io-40B4E5?logo=quay&logoColor=white)](https://quay.io/repository/ryan_nix/openclaw-openshift)
  [![SCC](https://img.shields.io/badge/SCC-restricted-success)](https://docs.openshift.com/container-platform/4.17/authentication/managing-security-context-constraints.html)

  <br/>

  *A production-ready container for running the [OpenClaw](https://github.com/openclaw/openclaw) AI agent gateway on OpenShift — built on Red Hat UBI 10, deployed entirely through Ansible. Bring your own AI provider and messaging channels.*

</div>

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Build the Container Image](#build-the-container-image)
- [Configuration Reference](#configuration-reference)
  - [AI Provider](#ai-provider)
  - [Messaging Channels](#messaging-channels)
  - [Custom Skills](#custom-skills)
- [Deploy to OpenShift](#deploy-to-openshift)
  - [Quick Start](#quick-start)
  - [With Messaging Channels](#with-messaging-channels)
  - [With Custom Skills](#with-custom-skills)
  - [Advanced Options](#advanced-options)
- [Post-Deploy Operations](#post-deploy-operations)
- [Channel Compatibility](#channel-compatibility)
- [Security Notes](#security-notes)

---

## Overview

OpenClaw is a self-hosted AI agent gateway that bridges AI models (Anthropic Claude, OpenAI, Google, xAI, and others) to messaging platforms you already use — Telegram, Discord, Slack, WhatsApp, Matrix, and more.

This project packages OpenClaw into a **multi-stage UBI 10 / Node.js 22** container that runs on OpenShift with zero privilege escalation (no `anyuid`, no custom SCC). An Ansible playbook handles every Kubernetes object: namespace, Secrets, ConfigMaps, PVCs, Deployment, Service, and Route.

**Key design decisions:**

| Concern | Approach |
|---|---|
| Secrets | OpenShift `Secret` → injected as env vars; never in ConfigMaps or image |
| Channel config | `ConfigMap` with `${ENV_VAR}` placeholders; tokens resolved at runtime |
| Custom skills | Init container copies from ConfigMap → workspace PVC on pod start |
| Persistence | Two RWO PVCs survive restarts, rebuilds, and redeployments |
| SCC | UID 1001 / GID 0 with `g+rwX` on data dirs — works with `restricted` |
| Strategy | `Recreate` (required by RWO PVCs) |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  OpenShift Namespace: openclaw-sandbox                      │
│                                                             │
│  ┌──────────────┐  ┌──────────────────┐                    │
│  │   Secret     │  │    ConfigMap      │                    │
│  │ credentials  │  │  channel-config  │                    │
│  │ (tokens/keys)│  │  custom-skills   │                    │
│  └──────┬───────┘  └────────┬─────────┘                    │
│         │ envFrom            │ volumeMount (ro)             │
│         ▼                    ▼                              │
│  ┌─────────────────────────────────────────────────┐       │
│  │  Pod                                             │       │
│  │  ┌─────────────────────┐                        │       │
│  │  │  Init: skills-      │── copies SKILL.md ──►  │       │
│  │  │  installer          │   to workspace PVC     │       │
│  │  └─────────────────────┘                        │       │
│  │  ┌─────────────────────────────────────────┐    │       │
│  │  │  openclaw-gateway  (port 18789)          │    │       │
│  │  │  UBI 10 / Node.js 22 / pnpm build       │    │       │
│  │  └──────────────┬──────────────────────────┘    │       │
│  └─────────────────┼────────────────────────────── ┘       │
│                    │                                        │
│          ┌─────────┴────────┐                              │
│          ▼                  ▼                              │
│  ┌──────────────┐  ┌──────────────────┐                    │
│  │  PVC: config │  │  PVC: workspace  │                    │
│  │  1 Gi RWO    │  │  2 Gi RWO        │                    │
│  │  openclaw.json│  │  skills/         │                   │
│  │  .env, memory│  │  agent files     │                    │
│  └──────────────┘  └──────────────────┘                    │
│                                                             │
│  ┌─────────────────────────────────────┐                   │
│  │  Route (edge TLS) → Service → Pod   │                   │
│  └─────────────────────────────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

### Tools

```bash
# Ansible + Kubernetes collection
pip install ansible kubernetes
ansible-galaxy collection install kubernetes.core

# OpenShift CLI
# https://console.redhat.com/openshift/downloads
oc version   # must be 4.14+

# Container build (choose one)
podman --version   # recommended
docker --version   # also works
```

### Accounts & access

| Requirement | Notes |
|---|---|
| OpenShift cluster | [Developer Sandbox](https://developers.redhat.com/developer-sandbox) is free and works out of the box |
| Quay.io account | Free at [quay.io](https://quay.io) — for pushing your built image |
| AI provider API key | Anthropic, OpenAI, Google, xAI, Mistral, or Cohere |
| Messaging bot tokens | Only for channels you actually want to enable |

### Log in to OpenShift

```bash
oc login \
  --token=<your-token> \
  --server=https://api.sandbox-xyz.openshiftapps.com:6443
```

> **Tip:** On the Developer Sandbox, copy the login command directly from the console under **"Copy login command"**.

---

## Project Structure

```
openclaw-on-openshift/
├── .github/
│   ├── logo.svg                         # Project logo
│   └── workflows/
│       └── build.yml                    # GitHub Actions CI/CD
├── templates/
│   └── channels-config.json.j2          # Jinja2 → channel ConfigMap
├── vars/
│   └── openclaw.yml                     # All deployment variables
├── skills/
│   └── satellite-cv-promote/
│       └── SKILL.md                     # Example custom skill
├── Containerfile                        # Multi-stage UBI 10 / Node.js 22 build
├── entrypoint.sh                        # Bootstrap + channel config + gateway start
├── openclaw-on-ocp.yml                      # Unified deploy & delete playbook
└── README.md
```

---

## CI/CD — GitHub Actions

The workflow at `.github/workflows/build.yml` handles all builds automatically.

### How it works

| Trigger | What happens |
|---|---|
| Push to `main` (Containerfile / entrypoint.sh) | Build + push `:latest`, `:YYYY.MM.DD`, `:git-<sha>` |
| Pull request to `main` | Build only — no push. Acts as a pre-merge check |
| Daily schedule (02:00 UTC) | Checks upstream OpenClaw release tag; rebuilds only if version changed |
| `workflow_dispatch` | Manual trigger with optional `force_rebuild` flag and `openclaw_ref` override |

### Tag strategy

| Tag | When applied |
|---|---|
| `:latest` | Every push to `main` and scheduled build |
| `:YYYY.MM.DD` | Every successful build |
| `:git-<short-sha>` | Every build — immutable reference |
| `:openclaw-<version>` | When upstream release tag is known (e.g. `:openclaw-2026.5.0`) |

### One-time Quay.io robot account setup

Using a robot account scoped to this repository is safer than using your Quay password directly.

1. Log in to [quay.io](https://quay.io) → **Account Settings** → **Robot Accounts** → **Create Robot Account**
2. Name it `openclaw_push` (will appear as `ryan_nix+openclaw_push`)
3. Under **Repositories**, grant it **Write** permission to `ryan_nix/openclaw-openshift`
4. Copy the generated token

Then add both values as GitHub Actions secrets (**Settings → Secrets and variables → Actions → New repository secret**):

| Secret name | Value |
|---|---|
| `QUAY_USERNAME` | `ryan_nix+openclaw_push` |
| `QUAY_PASSWORD` | *(robot account token)* |

### Manual build (local)

If you need to build outside of CI — for example to test a Containerfile change before pushing:

```bash
# Authenticate to Quay
podman login quay.io

# Build (linux/amd64 explicit — required when building on Apple Silicon)
podman build \
  --platform linux/amd64 \
  --tag quay.io/ryan_nix/openclaw-openshift:dev \
  .

# Push manually
podman push quay.io/ryan_nix/openclaw-openshift:dev
```

### Build a specific OpenClaw release

Use the `workflow_dispatch` trigger in the Actions tab and set `openclaw_ref` to a tag (e.g. `2026.5.0`). The workflow patches the Containerfile clone command to pin that ref before building, without modifying the committed file.

---

## Build the Container Image (manual)

> Most users won't need this — the GitHub Actions workflow handles builds automatically.
> Use this for local iteration when developing the Containerfile itself.

> ⚠️ **RAM note:** The `pnpm install` + `pnpm build` step requires ~2 GB of RAM.
> Build on your local machine or a CI runner — not on the OpenShift Sandbox (1 Gi limit).

### 1. Authenticate to Quay.io

```bash
podman login quay.io
```

### 2. Build the image

```bash
podman build \
  --tag quay.io/<your-quay-username>/openclaw-openshift:latest \
  .
```

For a version-pinned tag:

```bash
podman build \
  --tag quay.io/<your-quay-username>/openclaw-openshift:2026.5.0 \
  --tag quay.io/<your-quay-username>/openclaw-openshift:latest \
  .
```

### 3. Push to Quay.io

```bash
podman push quay.io/<your-quay-username>/openclaw-openshift:latest
```

### 4. Update the image reference

Edit `vars/openclaw.yml`:

```yaml
openclaw_image: "quay.io/<your-quay-username>/openclaw-openshift:latest"
```

### GitHub Actions (optional CI)

A minimal workflow to build and push on every commit to `main`:

```yaml
# .github/workflows/build.yml
name: Build & Push
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: redhat-actions/buildah-build@v2
        with:
          image: openclaw-openshift
          tags: latest ${{ github.sha }}
          containerfiles: ./Containerfile
      - uses: redhat-actions/push-to-registry@v2
        with:
          image: openclaw-openshift
          tags: latest ${{ github.sha }}
          registry: quay.io/${{ secrets.QUAY_USERNAME }}
          username: ${{ secrets.QUAY_USERNAME }}
          password: ${{ secrets.QUAY_PASSWORD }}
```

---

## Configuration Reference

All configuration lives in **`vars/openclaw.yml`**. Sensitive values should be encrypted with Ansible Vault.

### AI Provider

```yaml
# vars/openclaw.yml
ai_provider: anthropic    # anthropic | openai | google | xai | mistral | cohere
ai_api_key: "{{ vault_ai_api_key }}"

# Optional: pin a specific model. Leave empty to use the provider default.
# ai_model: "anthropic/claude-opus-4-6"
```

Encrypt your API key with Vault:

```bash
ansible-vault encrypt_string 'sk-ant-api03-...' \
  --name 'vault_ai_api_key' >> vars/openclaw.yml
```

**Supported providers, their env vars, and default models:**

| Provider | Env var | Default model |
|---|---|---|
| `anthropic` | `ANTHROPIC_API_KEY` | `anthropic/claude-sonnet-4-6` |
| `openai` | `OPENAI_API_KEY` | `openai/gpt-5.5` |
| `google` | `GOOGLE_API_KEY` | `google/gemini-2.5-pro` |
| `xai` | `XAI_API_KEY` | `xai/grok-3` |
| `mistral` | `MISTRAL_API_KEY` | `mistral/mistral-large-latest` |
| `cohere` | `COHERE_API_KEY` | `cohere/command-r-plus` |

The default model is written into `openclaw.json` at container startup via the entrypoint. Override it with `-e ai_model=<provider/model>` to pin a specific version without editing `vars/openclaw.yml`.

---

### Messaging Channels

Enable channels by setting `enabled: true` and supplying credentials. Tokens are stored in the OpenShift `Secret`; the channel config structure (with `${VAR}` placeholders) lives in a `ConfigMap`.

#### Telegram

1. Talk to [@BotFather](https://t.me/botfather) → `/newbot` → copy the token
2. Configure in `vars/openclaw.yml`:

```yaml
openclaw_channels:
  telegram:
    enabled: true
    bot_token: "{{ vault_telegram_bot_token }}"
    dm_policy: pairing       # pairing | open | allowlist
    allow_groups: false
```

#### Discord

1. [discord.com/developers](https://discord.com/developers) → New Application → Bot
2. Enable intents: **Message Content**, **Server Members**, **Guilds**, **Direct Messages**
3. Copy bot token and (optionally) your server's Guild ID:

```yaml
openclaw_channels:
  discord:
    enabled: true
    bot_token: "{{ vault_discord_bot_token }}"
    dm_policy: pairing
    slash_commands: true
    guild_id: "1234567890"   # optional — restrict to one server
    require_mention: true
```

#### Slack

1. [api.slack.com/apps](https://api.slack.com/apps) → Create App → **Socket Mode**
2. Add OAuth scopes: `app_mentions:read channels:history chat:write files:read files:write groups:history im:history im:read im:write`
3. Install to workspace and copy all three tokens:

```yaml
openclaw_channels:
  slack:
    enabled: true
    bot_token: "{{ vault_slack_bot_token }}"        # xoxb-...
    app_token: "{{ vault_slack_app_token }}"         # xapp-...
    signing_secret: "{{ vault_slack_signing_secret }}"
```

#### WhatsApp Business API

1. [developers.facebook.com](https://developers.facebook.com) → WhatsApp Business → create app
2. The playbook prints the webhook URL after deploying — register it in the Meta portal

```yaml
openclaw_channels:
  whatsapp_business:
    enabled: true
    access_token: "{{ vault_wa_access_token }}"
    phone_number_id: "1234567890"
    verify_token: "{{ vault_wa_verify_token }}"
```

> After deployment, register your Route URL as the Meta webhook:
> `https://openclaw-<namespace>.apps.<cluster>/webhook/whatsapp`

---

### Custom Skills

Skills are Markdown files (`SKILL.md`) with YAML frontmatter that teach the agent how to do specific jobs. The playbook stores them in a `ConfigMap`; an init container copies them into the workspace PVC on pod startup (idempotent — existing skills are never overwritten).

#### Skill format

```
skills/<skill-name>/SKILL.md
```

```markdown
---
name: my-skill
description: One-line summary written for the AI, not for humans.
version: 1.0.0
metadata:
  openclaw:
    requires:
      env:
        - MY_API_KEY
      bins:
        - curl
    primaryEnv: MY_API_KEY
---

# My skill

## When to use this skill
- When the user asks to do X
- When Y appears in the workspace

## Rules
1. Always confirm before running destructive commands.
2. Never expose credentials in output.

## Procedure
...
```

#### Adding skills to the deployment

```yaml
# vars/openclaw.yml
openclaw_custom_skills:
  - name: satellite-cv-promote
    skill_md: "{{ lookup('file', 'skills/satellite-cv-promote/SKILL.md') }}"
```

The `lookup('file', ...)` pattern means you maintain your `SKILL.md` as a real file in the repo. No inline YAML string escaping needed.

---

## Deploy to OpenShift

### Quick Start

Minimal deploy — gateway only, no messaging channels:

```bash
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  -e ai_api_key=sk-ant-api03-...
```

With Vault-encrypted credentials:

```bash
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  --ask-vault-pass
```

---

### With Messaging Channels

Pass channel config inline with `-e` for quick tests:

```bash
# Telegram
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  -e ai_api_key=sk-ant-... \
  -e '{"openclaw_channels":{"telegram":{"enabled":true,"bot_token":"7123:AAH..."}}}'

# Discord
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  -e ai_api_key=sk-ant-... \
  -e '{"openclaw_channels":{"discord":{"enabled":true,"bot_token":"MTk4...","guild_id":"1234567890"}}}'
```

For multi-channel setups, configure everything in `vars/openclaw.yml` and use Vault:

```bash
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  --ask-vault-pass
```

---

### With Custom Skills

Ensure `openclaw_custom_skills` is populated in `vars/openclaw.yml`, then deploy normally. The playbook will:

1. Create a `ConfigMap` with each skill's `SKILL.md` content
2. Add an init container (`skills-installer`) that copies skills into the workspace PVC
3. Skip any skill that already exists (protects runtime-installed skills)

```bash
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  --ask-vault-pass
```

Verify skills were installed:

```bash
oc exec -n openclaw-sandbox deploy/openclaw -- \
  ls /opt/openclaw/workspace/skills/
```

---

### Advanced Options

#### Switch AI providers

No image rebuild needed — the playbook rotates the Secret, updates the model config, and restarts the pod:

```bash
# Switch to OpenAI
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=openai \
  -e ai_api_key=sk-proj-...

# Switch to Anthropic and pin a specific model
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  -e ai_api_key=sk-ant-... \
  -e ai_model=anthropic/claude-opus-4-6
```

#### Switch models without redeploying

You can switch the model for the current session live from the Control UI chat:

```
/model anthropic/claude-sonnet-4-6
```

Or persist it permanently via `oc exec` (no pod restart needed — OpenClaw hot-reloads config):

```bash
oc exec deploy/openclaw -- \
  node dist/index.js config set \
  agents.defaults.model.primary \
  anthropic/claude-sonnet-4-6
```

#### Force rolling restart after image re-tag

```bash
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  -e ai_api_key=sk-ant-... \
  -e openclaw_force_restart=true
```

#### Override namespace or image

```bash
ansible-playbook openclaw-on-ocp.yml \
  -e ai_provider=anthropic \
  -e ai_api_key=sk-ant-... \
  -e openclaw_namespace=my-project \
  -e openclaw_image=quay.io/ryan_nix/openclaw-openshift:2026.5.0
```

---

## Post-Deploy Operations

### Access the Control UI

The playbook prints your Route URL and gateway token at the end of every run. You can also retrieve them at any time:

```bash
# Get the Route URL
oc get route openclaw \
  -o jsonpath='https://{.spec.host}{"\n"}'

# Retrieve the gateway token
oc get secret openclaw-credentials \
  -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d && echo
```

#### Step 1 — Open the Control UI

Navigate to your Route URL in a browser. The Gateway Dashboard login screen will appear with the WebSocket URL (`wss://...`) already pre-filled.

#### Step 2 — Paste the gateway token

Paste the token retrieved above into the **Gateway Token** field and click **Connect**.

> **Shortcut:** Append the token as a query parameter to skip the login prompt entirely:
> ```
> https://<route-host>/?token=<gateway-token>
> ```

#### Step 3 — Approve device pairing

On first connect from a new browser, OpenClaw requires the device to be explicitly approved as a security measure. You'll see an error like:

```
device pairing required (requestId: 95ed2db9-eff9-4666-baba-e073d77602a3)
```

Approve it from the terminal using the `requestId` shown on screen:

```bash
oc exec deploy/openclaw -- \
  node dist/index.js devices approve <requestId>
```

Then click **Connect** again in the browser. This is a one-time step per browser — once approved, the pairing is stored in the config PVC and future logins go straight through.

> **List pending approvals** if you need to check what's waiting:
> ```bash
> oc exec deploy/openclaw -- node dist/index.js devices list
> ```

---

### Securing the Route

The Control UI is protected by the gateway token, but for a public-facing deployment you should also restrict network access at the OpenShift router level.

#### Option 1 — IP allowlist (recommended)

Add the `ip_whitelist` annotation to the Route to restrict access to specific IPs or CIDRs. The playbook creates the Route with this annotation commented out — either uncomment it in `openclaw-on-ocp.yml` or patch it live:

```bash
# Restrict to a single IP
oc annotate route openclaw \
  haproxy.router.openshift.io/ip_whitelist="203.0.113.10/32" \
  --overwrite

# Allow a single IP plus an office subnet
oc annotate route openclaw \
  haproxy.router.openshift.io/ip_whitelist="203.0.113.10/32 10.10.0.0/16" \
  --overwrite

# Remove the restriction (allow all)
oc annotate route openclaw \
  haproxy.router.openshift.io/ip_whitelist- \
  --overwrite
```

To make the allowlist permanent, uncomment and edit this block in `openclaw-on-ocp.yml`:

```yaml
annotations:
  haproxy.router.openshift.io/ip_whitelist: "203.0.113.10/32 10.10.0.0/16"
```

> **Sandbox note:** The OpenShift Developer Sandbox router supports `ip_whitelist` but the annotation may be silently ignored depending on the cluster's HAProxy config. Test with `curl -I https://<route-host>` from a disallowed IP to verify.

#### Option 2 — NetworkPolicy (defence in depth)

Restrict which pods can reach the OpenClaw Service at the cluster network level, independent of the router:

```yaml
# networkpolicy-openclaw.yml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: openclaw-ingress
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: openclaw
  ingress:
    - from:
        # Allow OpenShift router pods (ingress traffic via the Route)
        - namespaceSelector:
            matchLabels:
              network.openshift.io/policy-group: ingress
      ports:
        - port: 18789
          protocol: TCP
```

```bash
oc apply -f networkpolicy-openclaw.yml
```

#### Option 3 — Rotate the gateway token

If you suspect your token has been compromised, rotate it immediately:

```bash
# Generate a new token
NEW_TOKEN=$(openssl rand -hex 32)

# Update the Secret
oc patch secret openclaw-credentials \
  --type='json' \
  -p="[{"op":"replace","path":"/data/OPENCLAW_GATEWAY_TOKEN","value":"$(echo -n $NEW_TOKEN | base64)"}]"

# Restart the pod to pick up the new token
oc rollout restart deployment/openclaw

echo "New token: $NEW_TOKEN"
```

---

### Deleting OpenClaw

```bash
# Remove all resources, preserve PVC data (config + workspace survive)
ansible-playbook openclaw-on-ocp.yml -e state=absent

# Remove everything including PVCs — PERMANENT DATA LOSS
ansible-playbook openclaw-on-ocp.yml -e state=absent -e delete_pvcs=true
```

The default (no `-e delete_pvcs=true`) keeps both PVCs intact so you can redeploy and pick up exactly where you left off — same config, memory, conversation history, and workspace files.

---

### Complete channel pairing

Telegram and Discord use a pairing-code model for first-contact DMs.
After the pod is `Running`:

```bash
# List pending pairing codes
oc exec -n openclaw-sandbox deploy/openclaw -- \
  node dist/index.js pairing list

# Approve a code (e.g. Telegram)
oc exec -n openclaw-sandbox deploy/openclaw -- \
  node dist/index.js pairing approve telegram <CODE>

# Approve a code (Discord)
oc exec -n openclaw-sandbox deploy/openclaw -- \
  node dist/index.js pairing approve discord <CODE>
```

Pairing codes expire after **1 hour**.

---

### Check agent and channel status

```bash
oc exec -n openclaw-sandbox deploy/openclaw -- \
  node dist/index.js status --deep
```

---

### Manage PVC data

```bash
# Open a shell inside the running pod
oc rsh -n openclaw-sandbox deploy/openclaw

# Browse the config PVC
ls /opt/openclaw/config/

# Browse the workspace and installed skills
ls /opt/openclaw/workspace/skills/
```

---

### Tail gateway logs

```bash
oc logs -n openclaw-sandbox deploy/openclaw -f
```

---

## Channel Compatibility

| Channel | Headless / container-safe | Notes |
|---|---|---|
| Telegram | ✅ Yes | Bot token from @BotFather |
| Discord | ✅ Yes | Bot token from developer portal |
| Slack | ✅ Yes | Three tokens (bot, app, signing secret) |
| WhatsApp Business API | ✅ Yes | Meta developer account + public HTTPS webhook |
| Matrix | ✅ Yes | Access token from any homeserver |
| Microsoft Teams | ✅ Yes | Azure bot registration |
| WhatsApp (Baileys) | ❌ No | Phone QR scan required on each startup |
| iMessage (BlueBubbles) | ❌ No | Requires BlueBubbles server running on a physical Mac |
| Signal | ❌ No | Interactive phone number registration required |
| macOS / iOS companion | ❌ No | Companion apps — not container-compatible |

---

## Security Notes

- **Tokens are never in the image or ConfigMaps.** All secrets live in the OpenShift `Secret` object and are injected as environment variables at runtime. OpenClaw resolves `${VAR_NAME}` references in the channel config JSON from those env vars.
- **Restricted SCC — no root, no privilege escalation.** The container runs as UID 1001 / GID 0. PVC directories are pre-owned `1001:0` with `chmod g+rwX` at image build time, satisfying OpenShift's arbitrary UID assignment without `anyuid`.
- **Review every ClawHub community skill before installing.** Skills are Markdown files that become agent instructions with potential tool access. Malicious skills have been distributed via ClawHub. Treat them like code review. The 53 built-in OpenClaw skills and any skills you write yourself are safe; community skills require manual inspection.
- **Rotate tokens periodically.** Re-run the playbook with new values — it will update the Secret and trigger a pod restart automatically via the channel-config-hash annotation.

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

OpenClaw is developed by the OpenClaw project authors. This is an independent containerization project and is not officially affiliated with Red Hat or the OpenClaw project.

---

<div align="center">
  <sub>Built on Red Hat UBI 10 · Deployed with Ansible · Running on OpenShift 🦞</sub>
</div>