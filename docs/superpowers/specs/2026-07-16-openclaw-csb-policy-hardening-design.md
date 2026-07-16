# OpenClaw CSB Policy Hardening Design

**Date:** 2026-07-16  
**Status:** Approved for implementation planning  
**Scope:** OpenClaw CSB running through OpenShell with the Podman compute driver

## Goal

Make the documented OpenShell deployment reproducible and demonstrably secure
while retaining OpenClaw command execution so the CSB demo can show useful
agent behavior.

## Non-Goals

- Disabling OpenClaw `exec` entirely.
- Supporting OpenShift or Kubernetes deployment.
- Turning the shared OpenClaw gateway into a multi-user authorization boundary.
- Allowing arbitrary runtime installation of skills or plugins.
- Replacing OpenShell with OpenClaw application policy.

## Current Problems

The repository and live validation identified these mismatches:

1. OpenClaw uses `tools.exec.mode: "full"`, so commands have no human approval
   boundary.
2. `skills.allowBundled: []` does not produce the documented result in
   OpenClaw 2026.7.1. Thirteen bundled skills remained eligible.
3. `skills.install.allowUploadedArchives: false` blocks uploaded archives, not
   ordinary ClawHub installation.
4. `csb/policy.yaml` uses the legacy OpenShell policy shape instead of the
   current canonical schema.
5. The README applies network access through several mutable post-creation
   commands rather than applying one version-controlled policy at creation.
6. Providers v2 can compose provider-owned network policy that is not visible
   in the repository policy.
7. `OPENCLAW_AI_ENV_VAR` is documented but unused.
8. The README generates a gateway token inline without retaining it for the
   operator.
9. Sandbox deletion and recreation do not automatically reattach the prior
   OpenShell-created workspace volume.
10. The README makes stronger claims about configuration immutability,
    marketplace blocking, and persistent upgrades than the implementation
    supports.

## Considered Approaches

### 1. Documentation-only correction

Correct the README but leave runtime behavior unchanged.

This has the lowest implementation cost, but it preserves unrestricted exec,
unexpected bundled skills, and incomplete installation controls. It does not
meet the CSB security objective.

### 2. Balanced approval-gated execution — selected

Keep exec available, require human approval for commands that are not already
trusted, use an explicit skill allowlist, fail closed on runtime installs, and
apply a canonical OpenShell policy during sandbox creation.

This retains the value of the demo while adding an authorization checkpoint
and making the effective containment policy reproducible.

### 3. Disable exec and all skills

Deny exec and expose only conversational/model capabilities.

This has the smallest agent attack surface, but it prevents the team-PR demo
and does not demonstrate the primary value of the solution. It is rejected.

## Selected Architecture

### OpenClaw application policy

The entrypoint will continue writing the CSB policy on every startup, with
these changes:

- Set `tools.exec.mode` to `ask`. Exec remains available, while non-trusted
  commands require a human decision through OpenClaw's approval flow.
- Keep elevated execution disabled and retain the existing denied tool list.
- Set `agents.defaults.skills` from `OPENCLAW_ALLOWED_SKILLS`, represented as a
  JSON array. The default is `[]`, which exposes no skills.
- Keep `skills.allowBundled: []` as defense in depth, but do not rely on it as
  the effective skill boundary.
- Configure `security.installPolicy` for both skills and plugins. A trusted,
  image-owned executable will return a fail-closed block decision for every
  runtime install or update request.
- Keep uploaded archives disabled, hooks disabled, cron disabled, elevated
  mode disabled, mDNS disabled, and filesystem tools workspace-only.

The repository's `team-prs` demo will opt in with:

```text
OPENCLAW_ALLOWED_SKILLS=["team-prs"]
```

The skill allowlist controls OpenClaw discovery and prompt visibility. It is
not treated as a shell authorization boundary; exec approval and OpenShell
remain required.

### OpenShell enforcement policy

`csb/policy.yaml` will use the current version-1 schema:

- `filesystem_policy`: system/application paths read-only; `/sandbox`, `/tmp`,
  and `/dev/null` read-write.
- `landlock.compatibility`: `best_effort`, preserving compatibility with the
  supported Podman environments while making warnings part of validation.
- `process`: agent child runs as `sandbox:sandbox`.
- `network_policies.openai`: only `/usr/bin/node` may reach
  `api.openai.com:443`, using inspected REST rules for required model paths.
- `network_policies.github`: only `/usr/bin/curl` may reach
  `api.github.com:443`, with read-only REST access.
- All unmatched destinations, binaries, methods, and paths remain denied.

The sandbox creation command will pass `--policy csb/policy.yaml`. Network
access will no longer depend on a sequence of post-creation updates.

Providers v2 policy composition will not be enabled in the baseline flow.
Providers will supply credential placeholders only, leaving the repository
policy authoritative. Runtime provider attach/detach will be documented as an
optional advanced mode that requires reviewing the resulting effective
policy.

### Podman persistence and exposure

The baseline deployment will:

- Create a named Podman volume owned outside the sandbox lifecycle.
- Mount it below `/sandbox` through `--driver-config-json` and point the
  OpenClaw config/workspace environment variables at that persistent path.
- Reuse the same named volume when recreating the sandbox for upgrades.
- Bind the local forward explicitly to `127.0.0.1:18789`.
- Set documented CPU and memory limits.
- Generate the gateway token into a shell variable, tell the operator to save
  it in an approved secret store, pass it to sandbox creation, and unset the
  local variable afterward.

The named-volume mount and ownership behavior must be proven on the configured
OpenShell Podman driver before the README claims upgrade persistence.

## Deployment Data Flow

1. The operator creates OpenAI and GitHub providers while Providers v2 policy
   composition is disabled.
2. The operator creates a named Podman volume and gateway token.
3. `openshell sandbox create` receives the CSB image, canonical policy,
   provider attachments, named-volume mount, resource limits, loopback
   forward, allowed skill list, and OpenClaw provider/model configuration.
4. OpenShell launches its supervisor and applies static filesystem/process
   policy before starting OpenClaw.
5. The OpenClaw entrypoint writes the approval-gated application policy and
   starts the gateway.
6. Model and GitHub calls carry resolver placeholders. OpenShell permits only
   matching binary/destination/request combinations and substitutes real
   provider credentials at the proxy boundary.
7. OpenClaw asks the human to approve exec requests that are not already
   trusted.

## Failure Handling

- Invalid OpenShell policy: sandbox creation must fail or load a restrictive
  fallback; validation treats either policy warnings or a policy mismatch as
  deployment failure.
- Missing provider: sandbox creation must fail before the demo is declared
  ready.
- Missing gateway token: the OpenClaw entrypoint exits non-zero.
- Invalid skill JSON: the entrypoint exits non-zero rather than exposing an
  unrestricted skill set.
- Missing install-policy executable or invalid response: OpenClaw install
  operations fail closed.
- Denied network request: the operator inspects OpenShell logs and changes the
  version-controlled policy only after review.
- Named-volume mount or ownership failure: validation stops before deleting an
  existing sandbox or claiming persistence.

## Validation Strategy

Behavior will be specified with EARS requirements and Gherkin scenarios before
implementation. Automated or scripted checks will cover:

- Exec remains available and an untrusted command requires approval.
- Only explicitly listed skills are model-visible.
- Runtime skill and plugin installation fails closed.
- Plugins remain disabled.
- The effective OpenShell policy matches the repository policy intent.
- Node can use the approved OpenAI REST paths.
- Curl can perform a GitHub GET but not a GitHub POST.
- Curl cannot reach OpenAI, and arbitrary destinations are denied.
- Provider environment values are OpenShell placeholders, not real secrets.
- `/sandbox` persistence survives sandbox deletion and recreation when the
  named Podman volume is reused.
- `/app` and `/etc` writes fail while persistent OpenClaw paths remain writable.
- The gateway accepts the generated token and rejects an invalid token.
- README commands match OpenShell 0.0.73 CLI syntax.

## Files Expected to Change

- `README.md`: replace the OpenShell deployment and security validation flow.
- `csb/policy.yaml`: migrate to the canonical policy schema and include exact
  network rules.
- `csb/entrypoint.sh`: approval-gated exec, explicit skill allowlist, and
  install-policy configuration.
- `csb/Containerfile`: install the trusted runtime install-policy executable.
- `csb/openclaw-install-policy`: new image-owned fail-closed policy command.
- `features/`: EARS requirements, executable Gherkin scenarios, and supporting
  test steps/scripts.

## Acceptance Criteria

The change is acceptable when a fresh Podman/OpenShell deployment following
the README reaches the OpenClaw Control UI, preserves exec behind approval,
exposes only the configured skills, blocks runtime installs, enforces the
documented network/filesystem boundaries, uses placeholder provider
credentials, and survives sandbox recreation with the configured named volume.

## Production-Hardening Addendum

The OCR review identified additional controls required before the image is
treated as production-ready:

- Every startup requires a newly supplied `OPENCLAW_GATEWAY_TOKEN`. Existing
  configuration is never accepted as an authentication fallback.
- The gateway token is not copied to `.env`. On upgrade, the entrypoint removes
  only a legacy `OPENCLAW_GATEWAY_TOKEN` assignment from an existing `.env`
  while preserving unrelated operator-managed values.
- `OPENCLAW_PUBLIC_URL` is accepted only as an absolute HTTP or HTTPS origin
  without credentials, path components, query parameters, or fragments.
- Provider configuration is a JSON object. Every provider name is non-empty,
  every provider value is an object, `api` and `baseUrl` are non-empty strings,
  `baseUrl` is an absolute HTTP or HTTPS URL without credentials, and an
  optional `apiKey` is a string.
- The generated `openclaw.json` is written to a mode-0600 temporary file in the
  configuration directory, synchronized, and atomically renamed over the
  destination.
- The runtime install-policy helper returns its block decision immediately;
  it does not wait for the request stream to close.
- The builder image and OpenClaw source are selected by immutable digests. The
  OpenClaw commit is
  `2d2ddc43d0dcf71f31283d780f9fe9ff4cc04fe4`, corresponding to the verified
  `v2026.7.1` tag, and dependency installation uses the committed lockfile.
- Repository tests execute the real configuration generator and inspect its
  observable output and failure behavior instead of relying solely on source
  text matching.

`gateway.bind = "lan"` remains intentional. OpenClaw must listen on the
container interface for OpenShell forwarding, while the host-facing OpenShell
forward remains bound to `127.0.0.1`.

The addendum is accepted when automated tests cover valid configuration,
invalid origins, invalid providers, missing tokens, legacy `.env` sanitation,
atomic replacement, immediate install denial, and immutable build inputs, and
when a locally built image starts successfully through Podman and OpenShell.
