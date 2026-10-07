# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/bitkaio/migratowl-action/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/bitkaio/migratowl-action/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/bitkaio/migratowl-action/releases/tag/v1.1.0
