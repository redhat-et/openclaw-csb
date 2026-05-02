# =============================================================================
# OpenClaw on UBI 10 — OpenShift-Compatible Container
# Maintainer: Ryan Nix <ryan.nix@gmail.com>
#
# Two-stage build:
#   builder  — UBI 10 Node 22 + pnpm + full source build
#   runtime  — UBI 10 Node 22 with compiled dist only
#
# OpenShift compatibility:
#   - Runs as UID 1001, GID 0 (arbitrary UID support for restricted SCC)
#   - No hardcoded secrets; all credentials injected via env vars from Secret
#   - Config/workspace directories are PVC-backed (see Ansible playbook)
#   - Gateway port 18789 exposed (non-privileged, >1024)
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Builder
# ---------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi10/nodejs-22:latest AS builder

LABEL stage="builder"

USER root
WORKDIR /build

# Install build toolchain needed for native node module compilation
# python3/make/gcc are required by some transitive pnpm dependencies
RUN dnf install -y \
      git \
      python3 \
      make \
      gcc \
      gcc-c++ && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# Install pnpm (OpenClaw's package manager)
# NOTE: pnpm install requires ~2 GB RAM; ensure your build host/runner has it
RUN npm install -g pnpm@latest

# Clone latest stable OpenClaw release
# Pin to a specific tag in production: --branch 2026.x.x
RUN git clone --depth 1 https://github.com/openclaw/openclaw.git .

# Install dependencies.
# --frozen-lockfile is intentionally omitted: OpenClaw's main branch moves
# quickly and the lockfile is often ahead of or behind package.json at the
# time of a fresh clone. --frozen-lockfile turns that normal drift into a
# hard build failure (ERR_PNPM_OUTDATED_LOCKFILE). We regenerate the
# lockfile inside the build context; it is never committed to this repo.
RUN pnpm install --no-frozen-lockfile

# Compile TypeScript → dist/ (separated from install for clearer log output)
RUN pnpm build

# Prune dev dependencies before copying to runtime stage
RUN pnpm prune --prod

# ---------------------------------------------------------------------------
# Stage 2: Runtime
# ---------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi10/nodejs-22:latest AS runtime

LABEL name="openclaw-openshift" \
      maintainer="Ryan Nix <ryan.nix@gmail.com>" \
      summary="OpenClaw AI agent gateway on UBI 10 for OpenShift" \
      description="Model-agnostic AI coding agent runtime, built on RHEL 10 UBI for restricted SCC compatibility" \
      io.k8s.display-name="OpenClaw UBI 10" \
      io.openshift.expose-services="18789:http" \
      io.openshift.tags="ai,agent,nodejs,ubi10"

USER root

# ---------------------------------------------------------------------------
# Directory layout
#   /app                 — compiled application (read-only at runtime)
#   /opt/openclaw/config — OpenClaw config + .env (PVC-backed)
#   /opt/openclaw/workspace — agent workspace (PVC-backed)
#
# GID 0 group ownership + g+rwX allows OpenShift's arbitrary assigned UID
# to write to these directories without running as root.
# ---------------------------------------------------------------------------
RUN mkdir -p /app /opt/openclaw/config /opt/openclaw/workspace && \
    chown -R 1001:0 /app /opt/openclaw && \
    chmod -R g=u /opt/openclaw && \
    chmod g+rwX /opt/openclaw /opt/openclaw/config /opt/openclaw/workspace

# Copy compiled app and production node_modules from builder
COPY --from=builder --chown=1001:0 /build/dist            /app/dist
COPY --from=builder --chown=1001:0 /build/node_modules    /app/node_modules
COPY --from=builder --chown=1001:0 /build/package.json    /app/package.json

# Copy entrypoint
COPY --chown=1001:0 entrypoint.sh /app/entrypoint.sh
RUN chmod 0755 /app/entrypoint.sh

# ---------------------------------------------------------------------------
# Runtime environment
#
# OPENCLAW_CONFIG_DIR    — where OpenClaw stores .env, memory, config
# OPENCLAW_WORKSPACE_DIR — agent working directory (files agent can read/write)
# HOME                   — must point to a writable location for Node.js internals
#
# AI provider keys (ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.) and
# OPENCLAW_GATEWAY_TOKEN are injected at runtime via OpenShift Secret.
# See deploy-openclaw.yml for Secret creation.
# ---------------------------------------------------------------------------
ENV OPENCLAW_CONFIG_DIR=/opt/openclaw/config \
    OPENCLAW_WORKSPACE_DIR=/opt/openclaw/workspace \
    NODE_ENV=production \
    HOME=/opt/openclaw \
    PATH=/app/node_modules/.bin:$PATH

WORKDIR /app

# OpenClaw gateway UI/API port (non-privileged)
EXPOSE 18789

# Drop to non-root UID with GID 0 for OpenShift restricted SCC
USER 1001

ENTRYPOINT ["/app/entrypoint.sh"]

