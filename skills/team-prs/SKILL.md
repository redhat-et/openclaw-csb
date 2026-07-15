---
name: team-prs
description: Use when looking up recent pull requests or issues filed by a group of GitHub users across all their projects. Invoke with /team-prs or when asked about team PR activity, contributions, or recent work by GitHub handles.
---

# Team PR & Issue Lookup

Look up recent PRs and issues for a set of GitHub handles across all repositories.

## Configuration

**GitHub handles** (add more as needed):

```
cooktheryan
sallyom
MichaelClifford
pavelanni
Ladas
kevincogan
ilya-kolchinsky
usize
tumido
srampal
nerdalert
```

**Lookback**: 7 days from today

## Instructions

1. Calculate the date 7 days ago from today using `date -d '7 days ago' +%Y-%m-%d` (Linux).

2. For each GitHub handle, use `curl` to query the GitHub Search API:

```bash
# Search PRs
curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/search/issues?q=author:<HANDLE>+type:pr+updated:>=$(date -d '7 days ago' +%Y-%m-%d)&per_page=50"

# Search Issues
curl -sf -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/search/issues?q=author:<HANDLE>+type:issue+updated:>=$(date -d '7 days ago' +%Y-%m-%d)&per_page=50"
```

3. Parse the JSON response. The results are in the `items` array with fields: `title`, `html_url`, `repository_url`, `state`, `updated_at`, `pull_request` (present if PR).

4. Format the results as a markdown report grouped by handle, then by type (PRs / Issues):

```
## @handle

### Pull Requests
| Title | Repo | State | Link |
|-------|------|-------|------|
| feat: add X | org/repo | merged | [PR #123](url) |

### Issues
| Title | Repo | State | Link |
|-------|------|-------|------|
| bug: Y broken | org/repo | open | [#456](url) |
```

5. If a handle has no results, show "No activity in the last 7 days."

## Adding Handles

Edit the **GitHub handles** list in this skill file to add or remove users. Group them however makes sense — by team, project, interest.
