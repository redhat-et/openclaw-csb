<!-- markdownlint-disable MD013 -->

# OpenClaw CSB on Podman with OpenShell

This repository builds an OpenClaw Corporate Standard Build (CSB) for Podman.
OpenShell supervises the container and enforces the filesystem, process,
network, and credential boundaries. This is not an OpenShift deployment.

The baseline intentionally keeps shell execution available so the solution can
demonstrate useful agent work. OpenClaw requires human approval when a command
misses its allowlist, and OpenShell independently limits what an approved
command can access.

## Architecture

```text
base/Containerfile          -> quay.io/redhat-et/openshell:base-latest
    |
    +-- csb/Containerfile   -> quay.io/redhat-et/openclaw:csb-latest
        +-- entrypoint.sh   application policy, rewritten at every start
        +-- policy.yaml     OpenShell sandbox policy
        +-- install policy  blocks runtime skill/plugin installation
```

The image is pinned to OpenClaw `v2026.7.1`. The documented local endpoint is
`http://localhost:18789` and is bound only to loopback.

## Prerequisites

- Podman with a running Podman machine where required by the host OS
- OpenShell `0.0.73` or later, with a local Podman-backed gateway selected
- `openssl`
- An OpenAI API key
- A GitHub token if using the included `team-prs` demonstration skill

Install OpenShell, then pin its local gateway to Podman. Do not rely on
auto-detection when a Docker-compatible Podman socket is also present.

```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
mkdir -p "$HOME/.config/openshell"
printf '%s\n' \
  '[openshell]' \
  'version = 1' \
  '' \
  '[openshell.gateway]' \
  'compute_drivers = ["podman"]' \
  >"$HOME/.config/openshell/gateway.toml"
```

Restart the gateway with the host's service manager, then verify it:

```bash
# macOS with Homebrew
brew services restart openshell

# Linux (use instead of the Homebrew command)
# systemctl --user restart openshell-gateway

openshell gateway list
openshell status
```

Run all commands below from the repository root.

## Deploy with OpenShell

### 1. Create credential providers

OpenShell stores the real credentials at its gateway and gives the sandbox
placeholder values. Do not put either API token in the sandbox creation
command.

```bash
read -rsp "OpenAI API key: " OPENAI_API_KEY && printf '\n'
export OPENAI_API_KEY
openshell provider create \
  --name openai \
  --type openai \
  --credential OPENAI_API_KEY
unset OPENAI_API_KEY

read -rsp "GitHub token: " GH_TOKEN && printf '\n'
export GH_TOKEN
openshell provider create \
  --name github \
  --type github \
  --credential GH_TOKEN
unset GH_TOKEN
```

This baseline uses providers for credentials only. It does not enable automatic
provider-policy composition; the version-controlled `csb/policy.yaml` remains
the authoritative sandbox policy. If the provider names already exist, inspect
them with `openshell provider get openai` and `openshell provider get github`
rather than recreating them.

### 2. Create persistent storage and a gateway token

The named Podman volume exists independently of the OpenShell sandbox. Reusing
it preserves OpenClaw state, device pairing, conversations, and workspace
skills when the sandbox is recreated.

```bash
podman volume create openclaw-csb-data
podman run --rm \
  --user 0 \
  --entrypoint /bin/sh \
  -v openclaw-csb-data:/data \
  quay.io/redhat-et/openclaw:csb-latest \
  -c 'chmod 0777 /data'

OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
printf 'Save this OpenClaw gateway token in an approved secret store: %s\n' \
  "$OPENCLAW_GATEWAY_TOKEN"
```

### 3. Create the policy-backed sandbox

The demo explicitly exposes only the repository's `team-prs` skill. Use `[]`
instead of `["team-prs"]` for a skill-free deployment.

```bash
openshell sandbox create \
  --name openclaw-csb \
  --from quay.io/redhat-et/openclaw:csb-latest \
  --cpu 2 \
  --memory 4Gi \
  --policy csb/policy.yaml \
  --provider openai \
  --provider github \
  --driver-config-json '{"podman":{"mounts":[{"type":"volume","source":"openclaw-csb-data","target":"/sandbox/persist","read_only":false}]}}' \
  --env OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN" \
  --env OPENCLAW_CONFIG_DIR=/sandbox/persist/.openclaw \
  --env OPENCLAW_WORKSPACE_DIR=/sandbox/persist/workspace \
  --env OPENCLAW_ALLOWED_SKILLS='["team-prs"]' \
  --env OPENCLAW_DEFAULT_MODEL=openai/gpt-5.5 \
  --env OPENCLAW_PROVIDERS='{"openai":{"api":"openai-responses","baseUrl":"https://api.openai.com/v1"}}' \
  -- /bin/true

unset OPENCLAW_GATEWAY_TOKEN
```

The short initial command returns control to the operator while OpenShell keeps
the sandbox. If creation fails because the name is already in use, remove the
old sandbox with `openshell sandbox delete openclaw-csb`.
The volume initialization uses mode `0777` because the OpenShell Podman driver
mounts an existing volume as root-owned before dropping the agent process to
UID/GID 1001. The volume is private to rootless Podman and mounted only into
this sandbox; all agent-created content is still owned by `sandbox:sandbox`.

### 4. Upload the demonstration skill

The allowlist controls discovery; the skill file must also exist in the
persistent workspace.

```bash
openshell sandbox exec -n openclaw-csb -- \
  mkdir -p /sandbox/persist/workspace/skills/team-prs
openshell sandbox upload openclaw-csb \
  skills/team-prs/SKILL.md \
  /sandbox/persist/workspace/skills/team-prs/SKILL.md
```

### 5. Start OpenClaw and the loopback forward

Start the gateway detached, then start an OpenShell-managed background forward.
The local bind is explicit so the Control UI is not exposed to the LAN.

```bash
openshell sandbox exec -n openclaw-csb -- /bin/sh -lc \
  'nohup /app/entrypoint.sh >/tmp/openclaw-gateway.log 2>&1 </dev/null &'
openshell forward start --background 127.0.0.1:18789 openclaw-csb
```

If the forward reports that the port is busy, stop the process using port
18789 or choose a different local port. Start a new agent conversation after
changing workspace skills so OpenClaw refreshes the prompt-visible snapshot.

### 6. Connect

Open `http://localhost:18789` and paste the saved gateway token. The forward is
bound to `127.0.0.1`; it is not exposed to the LAN.

## Validate the Deployment

### Confirm the effective policy

```bash
openshell sandbox get openclaw-csb --policy-only
```

Compare the result with `csb/policy.yaml`. It should show:

- `/sandbox`, `/tmp`, and `/dev/null` as the only declared writable paths
- the child process identity `sandbox:sandbox`
- OpenAI access only from `/usr/bin/node` for the three declared API routes
- read-only GitHub REST access only from `/usr/bin/curl`
- no policy entry for arbitrary internet destinations

### Confirm OpenClaw controls

```bash
openshell sandbox exec -n openclaw-csb -- \
  node /app/dist/index.js skills list
openshell sandbox exec -n openclaw-csb -- \
  node /app/dist/index.js security audit --deep
```

The skill list should expose `team-prs` and no bundled skills. The deep audit
should exercise the install-policy command and report that runtime skill and
plugin installation is blocked.

### Demonstrate useful, constrained exec

In the Control UI, ask OpenClaw to run `date`, then approve the command. Next,
invoke `/team-prs` and approve its `curl` command. This demonstrates that exec
is available while each allowlist miss remains subject to a human decision.

Then ask it to run these checks:

| Check | Expected result | Enforcement |
| --- | --- | --- |
| `curl https://api.github.com` | Allowed after approval | OpenClaw approval and OpenShell GitHub policy |
| `curl -X POST https://api.github.com/user` | Blocked | OpenShell read-only REST policy |
| `curl https://example.com` | Blocked | OpenShell default deny |
| Write `/sandbox/persist/workspace/proof.txt` | Allowed after approval | Both layers allow workspace writes |
| Write `/etc/proof.txt` | Blocked | OpenShell filesystem policy and unprivileged identity |
| Install a skill or plugin | Blocked | OpenClaw operator install policy |

Do not treat an HTTP `401` or `403` from an allowed upstream as a network-policy
failure: it still proves the route was reached. An OpenShell proxy denial or a
failed connection indicates a policy block.

## Upgrade and Recreate

Save the gateway token before deleting the sandbox. Then recreate it with the
same volume and the complete command from deployment step 3.

```bash
openshell sandbox delete openclaw-csb
podman pull quay.io/redhat-et/openclaw:csb-latest

# Repeat deployment steps 3 through 5 with the same openclaw-csb-data volume
# and saved OPENCLAW_GATEWAY_TOKEN, then validate the effective policy again.
```

Providers persist at the OpenShell gateway and application state persists in
`openclaw-csb-data`. The sandbox policy does not persist by accident: the
creation command reapplies the version-controlled file every time.

## Policy Model

OpenClaw decides which application features the agent may request. OpenShell
enforces what the process can actually access, including after a command is
approved.

### OpenClaw application controls

The entrypoint rewrites these settings at every start with
`OPENCLAW_NIX_MODE=1`:

| Control | CSB setting |
| --- | --- |
| Exec | Available with human approval (`tools.exec.mode: "ask"`) |
| Skills | Only `OPENCLAW_ALLOWED_SKILLS`; default `[]` |
| Bundled skills | Not allowed |
| Runtime skill/plugin install | Blocked by root-owned `security.installPolicy` |
| Plugins | Globally disabled with an empty allowlist |
| Browser, canvas, cron, web fetch/search | Denied |
| Elevated mode | Disabled |
| Filesystem tools | Workspace-only |
| Uploaded skill archives | Disabled |
| Hooks, cron, mDNS | Disabled |
| Runtime config mutation | Blocked by Nix mode |

The skill allowlist is a discovery and prompt-visibility control, not an OS
authorization boundary. Skill instructions can still request exec, so command
approval and OpenShell policy remain necessary.

### OpenShell enforcement controls

| Control | CSB setting |
| --- | --- |
| Process identity | `sandbox:sandbox` |
| Writable paths | `/sandbox`, `/tmp`, `/dev/null` |
| OpenAI | `/usr/bin/node`; GET models and POST responses/chat completions |
| GitHub | `/usr/bin/curl`; read-only REST access |
| Other destinations, binaries, methods, paths | Denied |
| Real provider credentials | Kept at gateway; placeholders supplied to sandbox |
| Landlock | Best-effort compatibility; inspect warnings during validation |

### Combined behavior

| Capability | OpenClaw | OpenShell | Result |
| --- | --- | --- | --- |
| Run an unallowlisted shell command | Requires approval | Runs as sandbox user | Allowed only after approval |
| Reach GitHub with curl | Exec approval | Read-only API policy | Approved GETs only |
| Reach an unlisted host | Exec approval | No matching policy | Blocked |
| Install runtime code | Install policy blocks | Network/filesystem still constrained | Blocked before install |
| Use file tools outside workspace | Workspace-only tools | Declared write paths only | Blocked |
| Read a provider secret | Placeholder visible | Real value retained at proxy | Real credential not exposed |

OpenClaw controls are defense in depth. OpenShell is the enforcement boundary
for arbitrary code executed inside the sandbox.

## Direct Podman Fallback

Running the image directly with Podman is useful for image troubleshooting, but
it does not provide OpenShell credential substitution or application-aware
network policy. The host port remains loopback-only.

```bash
OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
printf 'Save this gateway token: %s\n' "$OPENCLAW_GATEWAY_TOKEN"
printf '%s' "$OPENCLAW_GATEWAY_TOKEN" | \
  podman secret create openclaw-gateway-token -
unset OPENCLAW_GATEWAY_TOKEN
printf '%s' 'sk-proj-replace-me' | podman secret create openai-api-key -
podman volume create openclaw-csb-data
podman run --rm \
  --user 0 \
  --entrypoint /bin/sh \
  -v openclaw-csb-data:/data \
  quay.io/redhat-et/openclaw:csb-latest \
  -c 'chmod 0777 /data'

podman run -d --name openclaw-csb \
  --cpus 2 \
  --memory 4g \
  -p 127.0.0.1:18789:18789 \
  -v openclaw-csb-data:/sandbox/persist:Z \
  --secret openclaw-gateway-token \
  --secret openai-api-key \
  -e OPENCLAW_CONFIG_DIR=/sandbox/persist/.openclaw \
  -e OPENCLAW_WORKSPACE_DIR=/sandbox/persist/workspace \
  -e OPENCLAW_ALLOWED_SKILLS='[]' \
  -e OPENCLAW_DEFAULT_MODEL=openai/gpt-5.5 \
  -e OPENCLAW_PROVIDERS='{"openai":{"api":"openai-responses","baseUrl":"https://api.openai.com/v1"}}' \
  quay.io/redhat-et/openclaw:csb-latest
```

With direct Podman, provider credentials exist in the container and outbound
networking is not constrained by `csb/policy.yaml`. Use the OpenShell flow for
the CSB security posture.

## Build Locally

```bash
podman build \
  -f csb/Containerfile \
  --build-arg CSB_BASE_IMAGE=quay.io/redhat-et/openshell:base-latest \
  -t localhost/openclaw:csb-latest \
  .
```

Use `localhost/openclaw:csb-latest` in the deployment command to test the local
image. The OpenShell Podman driver and the shell running `podman build` must use
the same Podman engine.

## Model Provider Configuration

The entrypoint reads provider definitions in this order:

1. `$OPENCLAW_CONFIG_DIR/providers.json`
2. `/run/secrets/openclaw-providers`
3. `OPENCLAW_PROVIDERS`

Example `providers.json`:

```json
{
  "openai": {
    "api": "openai-responses",
    "baseUrl": "https://api.openai.com/v1"
  }
}
```

Provider definitions select the API protocol and base URL. OpenShell providers
separately supply credential placeholders. Change the default model with
`OPENCLAW_DEFAULT_MODEL`.

## CI/CD

GitHub Actions builds the base image, CSB image, and multi-architecture manifest
for amd64 and arm64. It also runs Trivy scanning and generates SPDX and
CycloneDX SBOMs.

| Repository | Image tags |
| --- | --- |
| `quay.io/redhat-et/openshell` | `base-latest`, `base-amd64-latest`, `base-arm64-latest` |
| `quay.io/redhat-et/openclaw` | `csb-latest`, `csb-amd64-latest`, `csb-arm64-latest` |

## Known Base-Image Workaround

The runtime copies Node.js 24 from the pinned upstream `bookworm-slim` image
because the current UBI Node builds contain SQLite 3.46.1. OpenClaw requires the
newer SQLite bundled with that runtime. Revisit the override when the UBI base
ships a compatible SQLite release.
