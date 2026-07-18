# Gateway Readiness Wait Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the documented detached OpenClaw startup wait for a healthy gateway before the loopback forward starts.

**Architecture:** Extend the existing OpenClaw CSB policy feature and repository-policy support layer with one readiness-ordering assertion. Update only the README shell workflow so the sandbox exec session remains alive until `/healthz` succeeds or startup fails.

**Tech Stack:** Markdown, POSIX shell invoked through `/bin/sh`, Python 3, Behave, EARS/Gherkin

## Global Constraints

- Keep `/app/entrypoint.sh` detached with `nohup`.
- Poll `http://127.0.0.1:18789/healthz` for no more than 30 seconds.
- Stop waiting early if the gateway process exits.
- Print `/tmp/openclaw-gateway.log` and return nonzero on failure.
- Start `openshell forward` only after the readiness-checked sandbox command succeeds.
- Do not change container images, application entrypoints, OpenShell policy, gateway configuration, or forwarding address.

---

### Task 1: Readiness-checked detached startup

**Files:**
- Modify: `features/0001-csb-policy.feature`
- Create: `features/steps/then/the_detached_gateway_should_be_ready_before_forwarding_begins.py`
- Modify: `features/support/repository_policy.py`
- Modify: `README.md`

**Interfaces:**
- Consumes: `RepositoryPolicy.readme`, loaded from the repository root.
- Produces: `RepositoryPolicy.assert_readme_waits_for_gateway_readiness()` and the Behave step `the detached gateway should be ready before forwarding begins`.

- [ ] **Step 1: Write the failing requirement and scenario**

Add this Rule to `features/0001-csb-policy.feature`:

```gherkin
  Rule: When an operator starts the detached gateway, the OpenShell README deployment shall wait for gateway readiness before starting the loopback forward.
    Scenario: Forwarding begins only after the gateway is healthy
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then the detached gateway should be ready before forwarding begins
```

Create the corresponding one-step file:

```python
from behave import then


@then("the detached gateway should be ready before forwarding begins")
def step_impl(context):
    context.policy.assert_readme_waits_for_gateway_readiness()
```

Add `assert_readme_waits_for_gateway_readiness()` to the support class. It must assert that the README contains detached startup, `gateway_pid=$!`, a 30-attempt `/healthz` loop, `kill -0` early-exit detection, diagnostic log output, and a nonzero failure exit. It must also compare string offsets to prove the forward command follows the readiness block.

- [ ] **Step 2: Run the new scenario to verify RED**

Run:

```bash
uvx --from 'behave<2' behave --name 'Forwarding begins only after the gateway is healthy'
```

Expected: FAIL because the current README has no readiness loop.

- [ ] **Step 3: Implement the minimal README workflow**

Replace the one-line detached startup command with:

```sh
openshell sandbox exec -n openclaw-csb -- /bin/sh -lc '
  nohup /app/entrypoint.sh >/tmp/openclaw-gateway.log 2>&1 </dev/null &
  gateway_pid=$!
  for i in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:18789/healthz >/dev/null; then
      exit 0
    fi
    if ! kill -0 "$gateway_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  cat /tmp/openclaw-gateway.log >&2
  exit 1
' &&
  openshell forward start --background 127.0.0.1:18789 openclaw-csb
```

Join the existing forward command to the readiness block with `&&`. Explain
briefly that failure prints the startup log and prevents the forward from
starting.

- [ ] **Step 4: Verify GREEN and audit the specification**

Run:

```bash
uvx --from 'behave<2' behave --name 'Forwarding begins only after the gateway is healthy'
python /Users/rcook/.codex/skills/ears-gherkin-dev/scripts/audit.py features/ --framework behave
git diff --check
```

Expected: the focused scenario passes, the audit reports zero findings, and `git diff --check` is silent. Run the full Behave suite and record the known baseline failures separately.

- [ ] **Step 5: Commit the behavior change**

```bash
git add README.md features/0001-csb-policy.feature \
  features/steps/then/the_detached_gateway_should_be_ready_before_forwarding_begins.py \
  features/support/repository_policy.py \
  docs/superpowers/plans/2026-07-18-gateway-readiness-wait.md
git commit -m "fix: wait for OpenClaw gateway readiness"
```
