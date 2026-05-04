# Architecture

OpenClaw on OpenShift — design decisions, storage layout, and security details.

---

## Deployment Architecture

```
OpenShift Namespace
│
├── Secret: openclaw-credentials
│   └── AI provider key, gateway token, channel tokens → injected as env vars
│
├── ConfigMap: openclaw-channel-config
│   └── Channel config JSON with ${ENV_VAR} placeholders (no secrets here)
│
├── ConfigMap: openclaw-custom-skills
│   └── SKILL.md content keyed by skill name
│
├── Pod
│   ├── Init: skills-installer
│   │   └── Copies skill files from ConfigMap → workspace PVC (no-clobber)
│   └── Container: openclaw-gateway (port 18789)
│       ├── Reads config from /opt/openclaw/.openclaw/ (config PVC)
│       └── Reads/writes workspace at /opt/openclaw/workspace/ (workspace PVC)
│
├── PVC: openclaw-config (1 Gi RWO)
│   └── openclaw.json, .env, agent memory, conversation history
│
├── PVC: openclaw-workspace (2 Gi RWO)
│   └── Agent workspace files, skills/
│
├── Service: openclaw (port 18789)
└── Route: edge TLS → Service
```

---

## Container Build

Multi-stage UBI 10 / Node.js 22 build:

**Stage 1 — builder:** Clones upstream OpenClaw, runs `pnpm install`, `pnpm build`, `pnpm ui:build`, then strips docs, test fixtures, source maps, and platform-specific native binaries before the runtime copy. `CI=true` is set in the builder stage only to prevent pnpm from requiring TTY confirmation.

**Stage 2 — runtime:** Clean `ubi10/nodejs-22` with only `dist/`, `node_modules/` (pruned to prod deps), `package.json`, `ui/`, and `docs/` copied in. The `docs/` directory is required at runtime for workspace templates like `AGENTS.md`.

Directory ownership is set to `1001:0` with `chmod g+rwX` so OpenShift's arbitrary UID assignment (e.g. `1013640000+`) works without `anyuid`.

---

## OpenShift SCC Compliance

The Deployment spec omits `fsGroup` and `runAsUser` entirely — OpenShift fills these from the namespace's SCC range. `hostUsers: false` satisfies `restricted-v3`. The init container drops all capabilities with `capabilities.drop: [ALL]`. No custom SCC or `anyuid` required.

Deployment strategy is `Recreate` because both PVCs are `ReadWriteOnce` and can only bind to one node at a time.

---

## Configuration Flow

At container startup, `entrypoint.sh` writes gateway config directly into `openclaw.json` via a Node.js heredoc — bypassing the `openclaw config set` CLI which requires the gateway to already be running. This handles:

- `gateway.mode = "local"`
- `gateway.bind = "lan"` (required for the OpenShift router to reach the pod)
- `gateway.controlUi.allowedOrigins` (includes the Route's public HTTPS URL to prevent CORS rejections)
- `gateway.auth.token` (from `OPENCLAW_GATEWAY_TOKEN`)
- `agents.defaults.model.primary` (from `OPENCLAW_DEFAULT_MODEL`)

Channel config is applied separately from a ConfigMap mounted at `/opt/openclaw/channel-config/`.

---

## Persistence

Both PVCs survive pod restarts, image rebuilds, and redeployments. The only way to lose data is to explicitly delete the PVCs (`-e delete_pvcs=true`).

| PVC | Mount | Contents |
|---|---|---|
| `openclaw-config` (1 Gi) | `/opt/openclaw/.openclaw` | `openclaw.json`, agent memory, conversation history |
| `openclaw-workspace` (2 Gi) | `/opt/openclaw/workspace` | Agent workspace files, `skills/` |

The config PVC mounts at `$HOME/.openclaw/` (i.e. `/opt/openclaw/.openclaw`) — the path OpenClaw uses by default, not a custom location.

---

## Security

### Secrets management

All tokens (AI provider key, gateway token, channel tokens) live in a single OpenShift `Secret` (`openclaw-credentials`) and are injected as environment variables at runtime. The channel ConfigMap holds only config structure with `${ENV_VAR}` placeholders — OpenClaw resolves these from the injected env vars at startup. No secrets are baked into the image or stored in ConfigMaps.

### Route security

The gateway token is the primary auth layer. For public deployments, add network-level restrictions:

**HAProxy IP allowlist** (router level):
```bash
oc annotate route openclaw \
  haproxy.router.openshift.io/ip_whitelist="203.0.113.10/32" \
  --overwrite
```

**NetworkPolicy** (cluster network level):
```yaml
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
        - namespaceSelector:
            matchLabels:
              network.openshift.io/policy-group: ingress
      ports:
        - port: 18789
          protocol: TCP
```

### Token rotation

```bash
NEW_TOKEN=$(openssl rand -hex 32)
oc patch secret openclaw-credentials --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/data/OPENCLAW_GATEWAY_TOKEN\",\"value\":\"$(echo -n $NEW_TOKEN | base64)\"}]"
oc rollout restart deployment/openclaw
echo "New token: $NEW_TOKEN"
```

### Device pairing

OpenClaw uses two-factor auth for browser connections: the gateway token proves you know the shared secret; device pairing proves which specific browser is connecting. The device identity is stored in `localStorage` — incognito windows and new browsers require a new pairing approval via `oc exec deploy/openclaw -- node dist/index.js devices approve <requestId>`.

### ClawHub skills

Community skills on ClawHub have been used to distribute malicious payloads. Treat any ClawHub skill like a code review before installing. Skills in this repo and OpenClaw's 53 built-in skills are safe.

---

## Topology View

The Deployment is annotated with `app.openshift.io/custom-icon` pointing to the OpenClaw lobster PNG at `.github/openclaw.png`, visible in the OpenShift Developer Console Topology view. `app.openshift.io/vcs-uri` links the node back to this repo.
