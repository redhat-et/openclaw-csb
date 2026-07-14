# =============================================================================
# OpenClaw on UBI 10 — OpenShift-Compatible Container
# Maintainer: Ryan Nix <ryan.nix@gmail.com>
#
# Two-stage build:
#   builder  — UBI 10 Node 24 + pnpm + full source build
#   runtime  — UBI 10 Node 24 with compiled dist only
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

# pnpm requires CI=true to run non-interactively in a container (no TTY).
# The GitHub Actions runner sets this in its own env, but buildah containers
# start with a clean UBI environment — so we set it explicitly here.
ENV CI=true

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
# Clone a specific release tag (passed by CI) instead of HEAD.
# HEAD of main moves daily and can be mid-development between releases,
# causing protocol mismatches between the UI and gateway.
ARG OPENCLAW_REF=main
RUN git clone --depth 1 --branch "${OPENCLAW_REF}"     https://github.com/openclaw/openclaw.git .

# ---------------------------------------------------------------------------
# Extension selection (opt-in plugins like codex, diagnostics-otel)
# OPENCLAW_EXTENSIONS is a comma- or space-separated list of plugin IDs.
# The docker-plugin-selection script landed upstream after v2026.6.11;
# when building from a release tag that lacks it, fall back to pnpm build
# which compiles all bundled extensions.
# ---------------------------------------------------------------------------
ARG OPENCLAW_EXTENSIONS=""
RUN if [ -f scripts/lib/docker-plugin-selection.mjs ]; then \
      node scripts/lib/docker-plugin-selection.mjs extensions "${OPENCLAW_EXTENSIONS}" \
        > /tmp/openclaw-selected-plugin-dirs; \
      touch /tmp/openclaw-plugin-selection-supported; \
      echo "Selected extensions:" && cat /tmp/openclaw-selected-plugin-dirs; \
    elif [ -n "${OPENCLAW_EXTENSIONS}" ]; then \
      echo "ERROR: OPENCLAW_EXTENSIONS='${OPENCLAW_EXTENSIONS}' was requested but scripts/lib/docker-plugin-selection.mjs is not available on this ref" >&2; \
      exit 1; \
    else \
      echo "Extension selection script not available on this ref — all extensions will be built"; \
    fi

# Install all dependencies (dev deps required for TypeScript compilation).
# --frozen-lockfile omitted intentionally — see comment on CI=true above.
RUN pnpm install --no-frozen-lockfile

# Compile TypeScript → dist/
# Uses pnpm build:docker with extension selection when available,
# falls back to pnpm build on older release tags.
RUN set -eu; \
    if [ -f /tmp/openclaw-plugin-selection-supported ]; then \
      selected_plugin_dirs="$(cat /tmp/openclaw-selected-plugin-dirs)"; \
      OPENCLAW_INTERNAL_DOCKER_BUILD_PLUGIN_IDS="$selected_plugin_dirs" \
      OPENCLAW_RUN_NODE_SKIP_DTS_BUILD=1 \
      NODE_OPTIONS="--max-old-space-size=8192" \
      pnpm_config_verify_deps_before_run=false pnpm build:docker; \
    else \
      pnpm build; \
    fi
RUN pnpm_config_verify_deps_before_run=false pnpm ui:build || pnpm ui:build

# Prune dev dependencies, then aggressively strip the node_modules tree
# before it gets COPY'd into the runtime stage.
#
# What each find pass removes:
#   *.md / *.txt / *.map / CHANGELOG* / LICENCE*
#     — docs and source maps are never needed at runtime (~15–25 MiB)
#   __tests__ / test / tests / spec
#     — test suites bundled inside packages (~10–20 MiB)
#   *.ts (but NOT *.d.ts — type declarations are sometimes required by
#     packages that do runtime require() of them; *.js.map is safe to drop)
#     — TypeScript source files left behind by packages that ship src/
#   .github / .circleci / .travis.yml / Makefile
#     — CI configs shipped inside npm packages
#   *.node pre-built binaries for platforms other than linux-x64
#     — native add-on variants for darwin/win32/arm64 (~20–40 MiB)
#
# pnpm store prune removes the content-addressable cache that accumulates
# during install; it lives under ~/.local/share/pnpm/store and is not
# referenced at runtime but would bloat the layer if not cleared.
RUN pnpm prune --prod && \
    find node_modules -maxdepth 4 \( \
        -name "*.md"        -o -name "*.MD"      \
        -o -name "*.txt"    -o -name "*.map"      \
        -o -name "CHANGELOG*" -o -name "LICENCE*" \
        -o -name "LICENSE"  -o -name "AUTHORS"    \
        -o -name ".travis.yml" -o -name ".eslintrc*" \
        -o -name "Makefile" -o -name "*.sh"       \
    \) -delete && \
    find node_modules -maxdepth 5 -type d \( \
        -name "__tests__" -o -name "test"  \
        -o -name "tests"  -o -name "spec"  \
        -o -name ".github" -o -name ".circleci" \
        -o -name "example" -o -name "examples"  \
    \) -exec rm -rf {} + 2>/dev/null || true && \
    find node_modules -maxdepth 6 -name "*.ts" ! -name "*.d.ts" -delete && \
    find node_modules -maxdepth 6 -name "*.js.map" -delete && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
      find node_modules -maxdepth 6 \( \
          -name "*darwin*" -o -name "*win32*" \
          -o -name "*freebsd*" -o -name "*linux-arm*" \
      \) -name "*.node" -delete 2>/dev/null || true; \
    else \
      find node_modules -maxdepth 6 \( \
          -name "*darwin*" -o -name "*win32*" \
          -o -name "*freebsd*" -o -name "*linux-x64*" \
      \) -name "*.node" -delete 2>/dev/null || true; \
    fi && \
    pnpm store prune --force 2>/dev/null || true

# ---------------------------------------------------------------------------
# Minimize attack surface — remove everything not needed at runtime.
# Only dist/extensions/<selected> survives; all extension source is removed.
# ---------------------------------------------------------------------------

# 1. Prune unselected extension dist and their exclusive node_modules deps.
#    Only runs when the Docker extension scripts are available.
RUN if [ -f scripts/prune-docker-plugin-dist.mjs ] && [ -f scripts/postinstall-bundled-plugins.mjs ] && [ -f /tmp/openclaw-plugin-selection-supported ]; then \
      OPENCLAW_EXTENSIONS="$(cat /tmp/openclaw-selected-plugin-dirs)" \
      OPENCLAW_BUNDLED_PLUGIN_DIR=extensions \
      node scripts/prune-docker-plugin-dist.mjs && \
      node scripts/postinstall-bundled-plugins.mjs; \
    fi

# 2. Resolve pnpm workspace symlinks to real copies before removing source.
RUN find node_modules -maxdepth 3 -type l | while read -r link; do \
      target="$(readlink -f "$link")" && \
      if [ -e "$target" ]; then \
        rm "$link" && cp -a "$target" "$link"; \
      fi; \
    done 2>/dev/null || true

# 3. Remove ALL extension/package source (only compiled dist/ is needed).
RUN rm -rf extensions/ packages/ patches/

# 4. Strip build tooling, VCS metadata, and dev artifacts.
RUN rm -rf .git .github .gitignore .gitattributes \
           .eslintrc* .prettierrc* .editorconfig \
           tsconfig*.json \
           pnpm-lock.yaml package-lock.json yarn.lock \
           pnpm-workspace.yaml .npmrc openclaw.mjs \
           tests test __tests__ \
           scripts \
           examples \
           ui/src/ \
           CONTRIBUTING.md SECURITY.md CHANGELOG.md \
           /tmp/openclaw-selected-plugin-dirs 2>/dev/null || true

# 5. Remove .d.ts and source maps from dist (not needed at runtime).
RUN find dist -type f \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o -name '*.map' \) -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# Stage 2: Runtime
# ---------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi10/nodejs-24:latest AS runtime

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

# Single defensive COPY — ship everything the builder produced.
# Dev/build junk (.git, tests, lint configs, lockfiles) was already stripped
# in the builder stage so /build contains only runtime-relevant files.
# This protects against upstream OpenClaw adding new runtime resource paths
# (e.g. src/agents/templates/HEARTBEAT.md in v2026.6.x).
COPY --from=builder --chown=1001:0 /build /app

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
