# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.5.0] - 2026-10-11

### Changed

- **A breaking upgrade no longer fails the commit status unless `fail-on-breaking` is on** — the scan now passes
  `fail-on-breaking` to Migratowl (0.8.2 or later), which otherwise sets the final status to success with the
  breaking count in its description. On GitLab a failed status had failed the whole MR pipeline.
- **`initial-wait` defaults to 30 seconds** (was 600) — the first poll came 10 minutes after submission even when
  the scan had finished in 3; the 30-second poll interval already covers sandbox start-up.

### Fixed

- **Sandbox role kept in sync with Migratowl** — the raw-mode Role now grants `get` as well as `create` on
  `pods/exec`, which the Kubernetes Python client needs to open exec streams, and `patch` on pods, which
  langchain-kubernetes uses to record sandbox activity. The Action's server uses kind's admin
  kubeconfig, so runs were not affected; the Role matches `k8s/rbac-raw.yaml` again.
- **The server installed Migratowl's development tools** — `uv sync` and `uv run` included the dev group (test,
  fuzzing and lint tools) on every run. The server now installs without it, as the GitLab component does.
- **The issue summary said "No breaking changes detected." when nothing was analyzed** — a scan that skipped
  every package (call budget, `max-deps`) read as all clear. The summary now lists skipped packages and says
  that nothing is confirmed safe when no package was analyzed.

## [1.4.0] - 2026-10-10

### Added

- **Scan diagnostics kept as an artifact** — every scan keeps the scan result and the Migratowl server log as the
  `migratowl-scan-<job>` workflow artifact (30 days), also when the scan fails, so a run can be diagnosed later.
  Same as the GitLab component.
- **🔍 Review in the issue summary** — packages the server flags for review (`reviews` in the result, Migratowl
  0.8 and later) are shown as such instead of as safe.

### Fixed

- **`results-destination: artifact` uploaded nothing** — the result was only copied into the workspace while the log
  said it was uploaded. The new artifact step covers it.

## [1.3.0] - 2026-10-09

Use with Migratowl 0.7.0 or later (`migratowl-version: latest` already resolves to it).

### Added

- **LLM proxy inputs** — `model-provider` (`anthropic` | `openai` | `litellm`; empty keeps the old automatic
  choice), `llm-base-url` (routed to `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL` or `LITELLM_BASE_URL`) and
  `model-alias` (`MIGRATOWL_MODEL_ALIAS`), matching the Migratowl server's proxy support. Same inputs and
  defaults as the GitLab component.

### Changed

- **Default `model` is now `claude-sonnet-5-5`** (was `claude-sonnet-5`; same price). Matches the new
  default in `bitkaio/migratowl`, which uses native structured output for Anthropic models — Claude Sonnet
  5.5 rejects the forced tool call the previous approach relied on, so use a Migratowl server version that
  includes this change. Set `model: claude-sonnet-5` to keep the previous model.

### Fixed

- **Sandboxes had no network access** — Migratowl attaches a deny-all `NetworkPolicy` to each raw-mode
  sandbox pod, and Calico enforces it, so DNS, `git clone` and package installs failed inside the scan.
  `scripts/start-kind.sh` now applies an egress policy that re-opens DNS and HTTP/HTTPS to public
  addresses only (same as `k8s/sandbox-egress-raw.yaml` in bitkaio/migratowl). Ingress, cluster CIDRs,
  node networks and cloud metadata stay blocked.

## [1.2.0] - 2026-07-16

### Changed

- **Default `model` bumped to `claude-sonnet-5`** (from `claude-sonnet-4-6`) — matches the default in
  `bitkaio/migratowl`. Applies to the `model` action input and the `start-migratowl.sh` fallback.
- **Cluster tooling bumped** — kind `v0.24.0` → `v0.32.0` (now defaults to Kubernetes 1.36.1) and
  Calico `v3.28.2` → `v3.32.1`, in `action.yml` and `scripts/start-kind.sh`.

## [1.1.0]

Marketplace release. GitHub Composite Action that spins up an ephemeral kind cluster with Calico CNI,
runs Migratowl in raw sandbox mode, and posts results as a PR comment, issue, or artifact.

[Unreleased]: https://github.com/bitkaio/migratowl-action/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/bitkaio/migratowl-action/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/bitkaio/migratowl-action/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/bitkaio/migratowl-action/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/bitkaio/migratowl-action/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/bitkaio/migratowl-action/releases/tag/v1.1.0
