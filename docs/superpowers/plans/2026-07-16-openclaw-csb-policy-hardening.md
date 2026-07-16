# OpenClaw CSB Policy Hardening Implementation Plan

<!-- markdownlint-disable MD013 MD032 -->

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the README deployment reproducible and accurate while retaining OpenClaw exec behind human approval and enforcing a version-controlled OpenShell policy.

**Architecture:** OpenClaw provides application-level approval, skill visibility, and install controls. OpenShell applies canonical static filesystem/process restrictions and exact binary-scoped REST egress rules at sandbox creation. Behave scenarios inspect repository artifacts, while a final live sandbox run validates effective behavior.

**Tech Stack:** Bash, Node.js 24, OpenClaw 2026.7.1, OpenShell 0.0.73, Podman 5.x, YAML, Python/Behave.

## Global Constraints

- OpenClaw exec remains enabled; `tools.exec.mode` is `ask`, never `deny`.
- The target is Podman through OpenShell on CSB laptops, not OpenShift or Kubernetes.
- The repository OpenShell policy is authoritative; Providers v2 policy composition is omitted from the baseline.
- Real provider credentials remain OpenShell-managed placeholders inside the sandbox.
- Runtime skill and plugin installation fails closed.
- Default skill visibility is empty; `team-prs` is explicitly enabled by deployment configuration.
- The local Control UI forward binds to `127.0.0.1:18789`.

---

### Task 1: Executable security requirements

**Files:**
- Create: `features/README.md`
- Create: `features/dashboard.html`
- Create: `features/0001-csb-policy.feature`
- Create: `features/steps/__init__.py`
- Create: `features/steps/given/the_openclaw_csb_repository.py`
- Create: `features/steps/when/the_csb_security_artifacts_are_inspected.py`
- Create: `features/steps/then/exec_should_require_human_approval.py`
- Create: `features/steps/then/skill_visibility_should_be_explicit.py`
- Create: `features/steps/then/runtime_installs_should_fail_closed.py`
- Create: `features/steps/then/the_openshell_policy_should_be_canonical_and_least_privilege.py`
- Create: `features/steps/then/the_readme_should_describe_the_reproducible_deployment.py`
- Create: `features/support/repository_policy.py`

**Interfaces:**
- Consumes: repository files `README.md`, `csb/entrypoint.sh`, `csb/policy.yaml`, `csb/Containerfile`, and `csb/openclaw-install-policy`.
- Produces: `RepositoryPolicy` assertions used by all Gherkin Then steps.

- [ ] **Step 1: Install the EARS/Gherkin browsing assets**

Copy the skill-provided `templates/README.md` and `templates/dashboard.html` into `features/` without modifying their contents.

- [ ] **Step 2: Write the EARS requirements and declarative scenarios**

Create `features/0001-csb-policy.feature`:

```gherkin
@security @csb
Feature: OpenClaw CSB policy
  The repository defines the application and sandbox boundaries used by the
  documented OpenShell deployment.

  Rule: The OpenClaw CSB policy shall retain exec behind human approval.
    Scenario: Exec remains available with an approval boundary
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then exec should require human approval

  Rule: The OpenClaw CSB policy shall expose only explicitly configured skills.
    Scenario: Skill visibility defaults to no skills
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then skill visibility should be explicit

  Rule: If a runtime skill or plugin installation is requested, then the OpenClaw CSB policy shall reject the installation.
    Scenario: Runtime customization fails closed
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then runtime installs should fail closed

  Rule: The OpenShell CSB policy shall authorize only declared filesystem, identity, and network access.
    Scenario: Canonical policy declares exact boundaries
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then the OpenShell policy should be canonical and least privilege

  Rule: The OpenShell README deployment shall apply version-controlled policy and persistent Podman storage.
    Scenario: Deployment instructions reproduce the security posture
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then the README should describe the reproducible deployment
```

- [ ] **Step 3: Write the support layer**

Create `features/support/repository_policy.py` with a `RepositoryPolicy` class that reads the five repository artifacts, parses `csb/policy.yaml` with `yaml.safe_load`, and exposes assertion methods for each Then step. Assertions must check exact strings/fields: `mode = "ask"`, JSON skill parsing with default `[]`, install-policy configuration, canonical OpenShell top-level keys, OpenAI Node rules, GitHub curl read-only access, `--policy csb/policy.yaml`, a Podman named volume mount, `127.0.0.1:18789`, and absence of `OPENCLAW_AI_ENV_VAR`.

- [ ] **Step 4: Write one thin step definition per file**

The Given creates `context.policy = RepositoryPolicy(Path.cwd())`; the When invokes `context.policy.load()`; each Then calls exactly one corresponding assertion method.

- [ ] **Step 5: Run scenarios to confirm RED**

Run:

```bash
uvx --from behave behave features/0001-csb-policy.feature
```

Expected: failures for exec mode, skill visibility, install policy, canonical OpenShell policy, and README deployment because implementation is unchanged.

- [ ] **Step 6: Audit the specification**

Run:

```bash
python /Users/rcook/.codex/skills/ears-gherkin-dev/scripts/audit.py features/
```

Expected: zero structural findings; scenario execution remains RED.

### Task 2: OpenClaw approval and customization policy

**Files:**
- Create: `csb/openclaw-install-policy`
- Modify: `csb/entrypoint.sh`
- Modify: `csb/Containerfile`
- Test: `features/0001-csb-policy.feature`

**Interfaces:**
- Consumes: `OPENCLAW_ALLOWED_SKILLS` as a JSON array string.
- Produces: `agents.defaults.skills`, `tools.exec.mode = "ask"`, and `security.installPolicy` in `openclaw.json`; `/usr/local/bin/openclaw-install-policy` returns an OpenClaw install-policy v1 block response.

- [ ] **Step 1: Add the fail-closed install policy executable**

Create an executable shell script that reads stdin and prints only:

```json
{"protocolVersion":1,"decision":"block","reason":"CSB policy prohibits runtime skill and plugin installation"}
```

- [ ] **Step 2: Copy the executable into the image**

Add to `csb/Containerfile` before switching back to UID 1001:

```dockerfile
COPY csb/openclaw-install-policy /usr/local/bin/openclaw-install-policy
RUN chmod 0755 /usr/local/bin/openclaw-install-policy
```

- [ ] **Step 3: Configure explicit skill visibility**

In the entrypoint Node block, parse `OPENCLAW_ALLOWED_SKILLS || "[]"`, reject non-array/non-string entries, and set `cfg.agents.defaults.skills` to the parsed array.

- [ ] **Step 4: Configure install rejection and exec approval**

Set `cfg.tools.exec.mode = "ask"`, and configure:

```javascript
cfg.security.installPolicy = {
  enabled: true,
  targets: ["skill", "plugin"],
  exec: {
    source: "exec",
    command: "/usr/local/bin/openclaw-install-policy",
    args: [],
    timeoutMs: 5000,
    noOutputTimeoutMs: 5000,
    maxOutputBytes: 4096,
    passEnv: [],
    env: {},
    trustedDirs: ["/usr/local/bin"]
  }
};
```

- [ ] **Step 5: Run the OpenClaw scenarios**

Run:

```bash
uvx --from behave behave features/0001-csb-policy.feature --name 'Exec remains available with an approval boundary' --name 'Skill visibility defaults to no skills' --name 'Runtime customization fails closed'
```

Expected: the three OpenClaw scenarios pass.

### Task 3: Canonical OpenShell policy

**Files:**
- Modify: `csb/policy.yaml`
- Test: `features/0001-csb-policy.feature`

**Interfaces:**
- Consumes: Node requests to the OpenAI API and curl requests to the GitHub API.
- Produces: canonical OpenShell v1 filesystem, Landlock, process, and network policy.

- [ ] **Step 1: Replace the legacy policy**

Use canonical top-level keys `version`, `filesystem_policy`, `landlock`, `process`, and `network_policies`. Declare read-only `/usr`, `/lib`, `/proc`, `/dev/urandom`, `/app`, `/etc`, `/var/log`; read-write `/sandbox`, `/tmp`, `/dev/null`; `sandbox:sandbox`; OpenAI inspected REST rules for `GET /v1/models`, `POST /v1/responses`, and `POST /v1/chat/completions` bound to `/usr/bin/node`; and GitHub `access: read-only` bound to `/usr/bin/curl`.

- [ ] **Step 2: Run the OpenShell policy scenario**

Run:

```bash
uvx --from behave behave features/0001-csb-policy.feature --name 'Canonical policy declares exact boundaries'
```

Expected: pass.

### Task 4: README deployment correction

**Files:**
- Modify: `README.md`
- Test: `features/0001-csb-policy.feature`

**Interfaces:**
- Consumes: policies and environment variables defined in Tasks 2 and 3.
- Produces: a reproducible OpenShell 0.0.73 + Podman deployment and verification guide.

- [ ] **Step 1: Rewrite provider setup**

Keep provider creation before sandbox creation, omit Providers v2 from the baseline, explain that the attached providers deliver placeholders only, and remove `OPENCLAW_AI_ENV_VAR`.

- [ ] **Step 2: Add persistent storage and token handling**

Create `openclaw-csb-data`, mount it read-write at `/sandbox/persist` using the Podman driver config, set config/workspace paths beneath it, generate the gateway token into an exported shell variable, and explicitly instruct the operator to save it in an approved secret store.

- [ ] **Step 3: Make creation deterministic**

Pass `--policy csb/policy.yaml`, `--cpu 2`, `--memory 4Gi`, `--forward 127.0.0.1:18789`, `OPENCLAW_ALLOWED_SKILLS='["team-prs"]'`, providers, model settings, and `/app/entrypoint.sh` in the create command.

- [ ] **Step 4: Correct security and upgrade claims**

Describe exec as approval-gated, skills as explicit visibility rather than a shell boundary, installation as fail-closed, Nix mode as supported-writer protection rather than filesystem immutability, and upgrades as sandbox recreation with named-volume reuse.

- [ ] **Step 5: Add validation commands**

Document effective-policy inspection, plugin/skill inventory, placeholder classification, allowed GitHub GET, denied GitHub POST, denied arbitrary egress, filesystem write checks, gateway token authentication, and OpenShell logs.

- [ ] **Step 6: Run the README scenario and Markdown lint**

Run:

```bash
uvx --from behave behave features/0001-csb-policy.feature --name 'Deployment instructions reproduce the security posture'
markdownlint README.md
```

Expected: both pass.

### Task 5: Full verification

**Files:**
- Verify: all files above

**Interfaces:**
- Consumes: completed repository artifacts.
- Produces: fresh static, behavioral, schema, and optional live-runtime evidence.

- [ ] **Step 1: Run all Gherkin scenarios and audit**

```bash
uvx --from behave behave features/0001-csb-policy.feature
python /Users/rcook/.codex/skills/ears-gherkin-dev/scripts/audit.py features/
```

Expected: all scenarios pass and the audit reports zero findings.

- [ ] **Step 2: Run syntax and formatting checks**

```bash
bash -n csb/entrypoint.sh csb/openclaw-install-policy
markdownlint README.md docs/superpowers/specs/2026-07-16-openclaw-csb-policy-hardening-design.md docs/superpowers/plans/2026-07-16-openclaw-csb-policy-hardening.md
git diff --check
```

Expected: exit 0.

- [ ] **Step 3: Validate a live sandbox when the local gateway is available**

Follow the README with a temporary sandbox name, inspect `openshell sandbox get --policy-only`, verify command approval in the Control UI, classify provider values without printing them, execute the documented allow/deny probes, recreate the sandbox with the named volume, and confirm a marker under `/sandbox/persist` survives.

Expected: behavior matches every README validation statement. If the gateway is unavailable, report live validation as not run rather than claiming it passed.

---

## Production-Hardening Addendum Plan

### Task 6: Executable configuration boundary

**Files:**
- Create: `csb/configure-openclaw.mjs`
- Modify: `csb/entrypoint.sh`
- Modify: `csb/Containerfile`
- Modify: `features/0001-csb-policy.feature`
- Modify: `features/support/repository_policy.py`
- Create: one Behave step file for each new Given, When, and Then phrase

**Interfaces:**
- Consumes: `OPENCLAW_GATEWAY_TOKEN`, optional `OPENCLAW_PUBLIC_URL`,
  `OPENCLAW_PROVIDERS`, and `OPENCLAW_ALLOWED_SKILLS`.
- Produces: an atomically replaced mode-0600 `openclaw.json`, or a non-zero
  exit with no replacement when any input is invalid.

- [ ] **Step 1: Add EARS rules and failing scenarios**

Specify mandatory startup authentication, valid origin/provider handling,
legacy `.env` sanitation, and atomic configuration replacement. Drive the
real configuration generator through the support layer using temporary
directories.

- [ ] **Step 2: Confirm RED**

Run `uvx --from behave behave features/0001-csb-policy.feature` and confirm the
new scenarios fail because `csb/configure-openclaw.mjs` does not exist.

- [ ] **Step 3: Implement the generator and entrypoint integration**

Move OpenClaw JSON construction from the shell heredoc into the image-owned
module. Validate tokens, origins, provider maps, provider URLs, optional API
keys, and allowed skills before writing. Write, synchronize, chmod, and rename
a temporary file in the destination directory. Require the token every time
and remove only the legacy token assignment from `.env`.

- [ ] **Step 4: Confirm GREEN**

Run all Behave scenarios and the EARS audit. Expected: all scenarios pass and
the audit reports zero findings.

### Task 7: Immediate install denial and immutable build inputs

**Files:**
- Modify: `csb/openclaw-install-policy`
- Modify: `csb/Containerfile`
- Modify: `features/0001-csb-policy.feature`
- Modify: `features/support/repository_policy.py`

**Interfaces:**
- Consumes: any install-policy request stream and the build context.
- Produces: an immediate protocol-v1 block response and a build pinned to the
  UBI builder digest and OpenClaw commit
  `2d2ddc43d0dcf71f31283d780f9fe9ff4cc04fe4` using `--frozen-lockfile`.

- [ ] **Step 1: Add failing behavioral scenarios**

Run the install helper with stdin deliberately left open and require the block
response within one second. Inspect parsed Containerfile instructions for the
builder digest, exact OpenClaw commit verification, and frozen lockfile flag.

- [ ] **Step 2: Confirm RED**

Run the two targeted scenarios. Expected: the install helper times out and the
build-input assertion fails.

- [ ] **Step 3: Implement minimum hardening**

Remove the stdin drain, pin the builder manifest-list digest, fetch and verify
the exact OpenClaw commit, and replace `--no-frozen-lockfile` with
`--frozen-lockfile`.

- [ ] **Step 4: Confirm GREEN**

Run all Behave scenarios, the EARS audit, shell syntax checks, Markdown lint,
and `git diff --check`. Expected: all commands exit zero.

### Task 8: Local Podman and OpenShell acceptance

**Files:**
- Verify: `csb/Containerfile`, `csb/entrypoint.sh`, `csb/policy.yaml`, and
  `README.md`

**Interfaces:**
- Consumes: the locally built CSB image, named Podman volume, gateway token,
  and OpenShell Podman driver.
- Produces: runtime evidence for startup, authentication, policy application,
  approved execution, filesystem/network denial, and persistence.

- [ ] **Step 1: Restore local Podman health without deleting user data**

Restart the Podman machine and recheck `podman info`. If overlay corruption
persists, stop and report that a destructive store reset requires explicit
approval.

- [ ] **Step 2: Build the image locally**

Run the README build with the configured CSB base image and a local validation
tag. Expected: the frozen dependency install, OpenClaw build, and runtime image
assembly exit zero.

- [ ] **Step 3: Exercise direct Podman startup**

Use temporary config/workspace mounts and a generated token. Verify the health
endpoint accepts the correct token path, the generated config contains the
expected policy, and startup without a token fails.

- [ ] **Step 4: Exercise the OpenShell scenario**

Create a temporary sandbox with `csb/policy.yaml`, start a loopback forward,
inspect effective policy and OpenClaw controls, verify approved useful command
execution plus documented filesystem/network denials, and recreate with the
named volume to prove persistence.

- [ ] **Step 5: Clean up validation resources**

Remove only the temporary sandbox, forward, container, and volume created by
this task. Preserve existing user resources.
