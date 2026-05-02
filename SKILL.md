---
name: satellite-cv-promote
description: Promote a Red Hat Satellite 6.x content view version to a lifecycle environment using the hammer CLI.
version: 1.0.0
metadata:
  openclaw:
    emoji: "🛰️"
    requires:
      env:
        - SATELLITE_URL
        - SATELLITE_USERNAME
        - SATELLITE_PASSWORD
      bins:
        - hammer
    primaryEnv: SATELLITE_URL
---

# Red Hat Satellite — content view promotion

## When to use this skill

- When the user asks to "promote a content view", "publish a CV version", or "move
  content to [lifecycle environment]" in Red Hat Satellite.
- When the user asks to check available content view versions before promoting.

## Rules

1. Always confirm the organization name, content view name, version label, and
   target lifecycle environment before running any `hammer` command.
2. Use `hammer content-view version list` to identify the correct version ID before
   promoting — never guess version IDs.
3. Use environment variables for credentials — never echo or log them:
   `hammer --username "$SATELLITE_USERNAME" --password "$SATELLITE_PASSWORD" --server "$SATELLITE_URL"`
4. After triggering a promote, poll task progress with `hammer task progress --id <task_id>`
   every 10 seconds until complete or failed.
5. **Never promote to the Production environment without explicit user confirmation.**
   Always ask: "Are you sure you want to promote to Production? This affects live systems."
6. If `hammer` is not available, report this clearly and suggest the user ensure the
   `foreman-cli` package is installed in the container.

## Procedure

### Step 1 — List available content views

```bash
hammer content-view list \
  --organization "$ORG_NAME" \
  --server "$SATELLITE_URL" \
  --username "$SATELLITE_USERNAME" \
  --password "$SATELLITE_PASSWORD"
```

### Step 2 — List versions for a specific content view

```bash
hammer content-view version list \
  --content-view "$CV_NAME" \
  --organization "$ORG_NAME" \
  --server "$SATELLITE_URL" \
  --username "$SATELLITE_USERNAME" \
  --password "$SATELLITE_PASSWORD"
```

### Step 3 — Promote to target lifecycle environment

```bash
hammer content-view version promote \
  --id "$VERSION_ID" \
  --to-lifecycle-environment "$TARGET_ENV" \
  --organization "$ORG_NAME" \
  --server "$SATELLITE_URL" \
  --username "$SATELLITE_USERNAME" \
  --password "$SATELLITE_PASSWORD"
```

### Step 4 — Monitor task progress

Capture the task ID from the output of Step 3 and poll until done:

```bash
hammer task progress \
  --id "$TASK_ID" \
  --server "$SATELLITE_URL" \
  --username "$SATELLITE_USERNAME" \
  --password "$SATELLITE_PASSWORD"
```

## Output format

Report results in this format:

```
Content View : <cv_name>
Version      : <version_label> (ID: <version_id>)
Promoted to  : <lifecycle_environment>
Task ID      : <task_id>
Status       : <Pending / Running / Completed / Failed>
```

If the task fails, display the full error message and suggest checking
`/var/log/foreman/production.log` on the Satellite server.
