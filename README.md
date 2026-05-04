# migratowl-action

> **Using an existing Kubernetes cluster?**
> This Action spins up a temporary cluster inside the GitHub runner — no infrastructure required.
> If your team already operates a Kubernetes cluster, use the self-hosted deployment instead:
> see [bitkaio/migratowl](https://github.com/bitkaio/migratowl) for setup instructions.

---

AI-powered dependency migration analyzer for GitHub Actions. Migratowl discovers breaking upgrades, explains exactly what failed, and tells you how to fix it — automatically, on every Dependabot or Renovate PR.

No Kubernetes cluster required. The Action spins up a temporary [kind](https://kind.sigs.k8s.io/) cluster inside the runner, runs the scan in an isolated sandbox, posts results as a PR comment, then tears everything down.

## Usage

### PR mode — bot PRs only (default)

Scans Dependabot and Renovate PRs automatically. Human-authored PRs are skipped.

```yaml
name: migratowl
on:
  pull_request:
    branches: [main]
concurrency:
  group: migratowl-${{ github.ref }}
  cancel-in-progress: true
permissions:
  contents: read
  pull-requests: write
  statuses: write
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: bitkaio/migratowl-action@v1
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          # scan-trigger: bot          # default — Dependabot/Renovate PRs only
          # scan-trigger: deps-changed # any PR that touches dependency files
          # scan-trigger: always       # every PR (higher cost)
```

### Scheduled mode — weekly full-repo scan

Results are auto-posted to a GitHub Issue labelled `migratowl-report`. On each run the existing issue is updated in place, or a new one is created. No setup needed beyond the workflow and the secret.

```yaml
name: migratowl-weekly
on:
  schedule:
    - cron: '0 9 * * 1'   # Mondays at 09:00 UTC
permissions:
  contents: read
  issues: write
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: bitkaio/migratowl-action@v1
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          results-destination: issue   # auto-creates or updates issue labelled migratowl-report
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `anthropic-api-key` | — | Required unless `openai-api-key` is set. |
| `openai-api-key` | — | Alternative to Anthropic; sets `MIGRATOWL_MODEL_PROVIDER=openai`. |
| `model` | `claude-sonnet-4-6` | Passed to `MIGRATOWL_MODEL_NAME`. |
| `mode` | `normal` | `safe` \| `normal`. |
| `ecosystems` | `""` | Comma-separated; empty = auto-detect all. |
| `exclude-deps` | `""` | Comma-separated package names to skip. |
| `check-deps` | auto | On Dependabot/Renovate PRs, auto-populated. Override to force specific deps. |
| `max-deps` | `50` | Hard cap on outdated deps to analyze. |
| `include-prerelease` | `false` | Consider pre-release versions. |
| `confidence-threshold` | `0.7` | Passed to `MIGRATOWL_CONFIDENCE_THRESHOLD`. |
| `migratowl-version` | `latest` | Pins the runtime image and server version. |
| `scan-trigger` | `bot` | `bot` \| `deps-changed` \| `always`. Controls which PRs trigger a scan. Ignored on `schedule` triggers. |
| `results-destination` | `pr-comment` | `pr-comment` \| `issue` \| `artifact`. On `schedule` triggers `pr-comment` is invalid. |
| `fail-on-breaking` | `false` | Exit non-zero when `is_breaking: true` is found. Keep `false` until confidence scoring is validated. |
| `initial-wait` | `600` | Seconds to wait before the first poll. Covers sandbox spin-up so early polls aren't wasted. |
| `poll-interval` | `30` | Seconds between job-status polls. |
| `scan-timeout` | `3600` | Total seconds before giving up on a scan (deadline-based, not a fixed poll count). |

## Required permissions

```yaml
permissions:
  contents: read
  pull-requests: write   # for pr-comment destination
  statuses: write        # for commit status
  issues: write          # for issue destination only
```

Use only the permissions your workflow needs. For scheduled mode with `results-destination: issue`, drop `pull-requests: write` and add `issues: write`.

## How it works

1. **Determine scan eligibility** — reads the PR author and changed files; skips the entire run when the `scan-trigger` policy is not met (before any expensive setup).
2. **Create kind cluster** — spins up a single-node [kind](https://kind.sigs.k8s.io/) cluster with [Calico CNI](https://projectcalico.docs.tigera.io/) so `NetworkPolicy` is actually enforced.
3. **Pull runtime image** — pulls `ghcr.io/bitkaio/migratowl-runtime:<version>` (prebuilt multi-arch image containing Python, Node.js, Go, Rust, and Java runtimes) and loads it into the cluster.
4. **Start Migratowl server** — clones `bitkaio/migratowl` at the pinned version, installs via `uv sync`, starts `uvicorn` on `127.0.0.1:8000`.
5. **Extract dependencies** — on Dependabot and Renovate PRs, auto-extracts bumped package names for a targeted scan (10–50× cheaper than a full scan). For Renovate grouped updates, parses the PR body table; falls back to a full scan if the table is absent.
6. **Trigger scan** — `POST /webhook`, waits `initial-wait` seconds (default 600s) to let the sandbox spin up, then polls `/jobs/{id}` every `poll-interval` seconds (default 30s) up to `scan-timeout` seconds (default 3600s).
7. **Route results** — posts a PR comment (via Migratowl's built-in GitHub integration), updates/creates a tracked issue, or emits a workflow artifact depending on `results-destination`.

## Advanced configuration

For advanced configuration, self-hosted deployment, or enterprise Kubernetes clusters, see [bitkaio/migratowl](https://github.com/bitkaio/migratowl).
