# Gateway Readiness Wait Design

## Problem

The documented detached startup command backgrounds `/app/entrypoint.sh` and
immediately lets the `openshell sandbox exec` session end. OpenClaw may not
finish initializing before that session closes. The subsequent OpenShell
forward can therefore be healthy while no gateway process is accepting HTTP
connections, which leaves the Control UI inaccessible.

The existing acceptance specification checks that the README contains both the
startup and forwarding commands, but it does not require the startup command to
prove gateway readiness before returning.

## Scope

Change only the documented startup workflow and its executable acceptance
specification. Do not change the image entrypoint, container build, OpenShell
policy, port forwarding command, or gateway configuration.

## Design

The README startup command will:

1. start `/app/entrypoint.sh` with `nohup` and capture its process ID;
2. poll `http://127.0.0.1:18789/healthz` for up to 30 seconds;
3. exit successfully only after the health endpoint responds successfully;
4. stop waiting early if the gateway process exits; and
5. print `/tmp/openclaw-gateway.log` and exit nonzero when startup fails or
   times out.

The OpenShell background forward remains a separate command and therefore
starts only after the readiness-checked `sandbox exec` command succeeds.

## Requirements and Verification

Add an event-driven EARS requirement to the existing OpenClaw CSB policy
feature: when an operator starts the detached gateway, the README deployment
shall wait for gateway readiness before starting the loopback forward.

Add a declarative Gherkin scenario backed by the existing repository support
layer. The regression assertion will verify the ordering and essential shell
contract: detached entrypoint startup, PID capture, bounded health polling,
early process-exit detection, diagnostic log output, and forwarding only after
the startup command block.

Verification consists of observing the new scenario fail against the current
README, updating the README minimally, observing the scenario and full feature
suite pass, running the EARS/Gherkin audit, and checking shell snippets and
repository formatting where supported.
