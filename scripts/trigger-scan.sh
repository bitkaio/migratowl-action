#!/usr/bin/env bash
# Posts a scan request to the Migratowl API, polls until completion,
# and handles result routing (pr-comment, issue, artifact).

set -euo pipefail

REPO_URL="${REPO_URL:-}"
BRANCH_NAME="${BRANCH_NAME:-}"
PR_NUMBER="${PR_NUMBER:-}"
COMMIT_SHA_PR="${COMMIT_SHA_PR:-}"
COMMIT_SHA_PUSH="${COMMIT_SHA_PUSH:-}"
MAX_DEPS="${MAX_DEPS:-50}"
MODE="${MODE:-normal}"
INCLUDE_PRERELEASE="${INCLUDE_PRERELEASE:-false}"
EXCLUDE_DEPS="${EXCLUDE_DEPS:-}"
ECOSYSTEMS="${ECOSYSTEMS:-}"
RESULTS_DESTINATION="${RESULTS_DESTINATION:-pr-comment}"
FAIL_ON_BREAKING="${FAIL_ON_BREAKING:-false}"
INITIAL_WAIT="${INITIAL_WAIT:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-3600}"
GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
MIGRATOWL_CHECK_DEPS="${MIGRATOWL_CHECK_DEPS:-[]}"

log() { echo "[migratowl/trigger-scan] $*"; }

# ── Build payload ─────────────────────────────────────────────────────────────

COMMIT_SHA="${COMMIT_SHA_PR:-$COMMIT_SHA_PUSH}"

# Convert comma-separated strings to JSON arrays.
if [ -z "$ECOSYSTEMS" ]; then
  ECOSYSTEMS_JSON="null"
else
  ECOSYSTEMS_JSON=$(echo "$ECOSYSTEMS" | python3 -c \
    "import sys,json; s=sys.stdin.read().strip(); print(json.dumps([x.strip() for x in s.split(',') if x.strip()]))")
fi

if [ -z "$EXCLUDE_DEPS" ]; then
  EXCLUDE_DEPS_JSON="[]"
else
  EXCLUDE_DEPS_JSON=$(echo "$EXCLUDE_DEPS" | python3 -c \
    "import sys,json; s=sys.stdin.read().strip(); print(json.dumps([x.strip() for x in s.split(',') if x.strip()]))")
fi

# Resolve pr_number: must be an integer or null.
if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ] || [ "$GITHUB_EVENT_NAME" = "schedule" ]; then
  PR_NUMBER_JSON="null"
else
  PR_NUMBER_JSON="$PR_NUMBER"
fi

# Resolve commit_sha: null when empty.
if [ -z "$COMMIT_SHA" ]; then
  COMMIT_SHA_JSON="null"
else
  COMMIT_SHA_JSON="\"$COMMIT_SHA\""
fi

PAYLOAD=$(jq -n \
  --arg  repo_url            "$REPO_URL" \
  --arg  branch_name         "$BRANCH_NAME" \
  --argjson pr_number        "$PR_NUMBER_JSON" \
  --argjson commit_sha       "$COMMIT_SHA_JSON" \
  --argjson check_deps       "$MIGRATOWL_CHECK_DEPS" \
  --argjson max_deps         "$MAX_DEPS" \
  --arg    mode              "$MODE" \
  --argjson include_prerelease "$([ "$INCLUDE_PRERELEASE" = "true" ] && echo true || echo false)" \
  --argjson exclude_deps     "$EXCLUDE_DEPS_JSON" \
  --argjson ecosystems       "$ECOSYSTEMS_JSON" \
  '{
    repo_url:          $repo_url,
    branch_name:       $branch_name,
    git_provider:      "github",
    pr_number:         $pr_number,
    commit_sha:        $commit_sha,
    check_deps:        $check_deps,
    max_deps:          $max_deps,
    mode:              $mode,
    include_prerelease: $include_prerelease,
    exclude_deps:      $exclude_deps,
    ecosystems:        $ecosystems
  }')

log "Payload: $(echo "$PAYLOAD" | jq -c .)"

# ── Trigger scan ──────────────────────────────────────────────────────────────
log "POST /webhook"
WEBHOOK_RESPONSE=$(curl --fail-with-body -sX POST http://127.0.0.1:8000/webhook \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

JOB_ID=$(echo "$WEBHOOK_RESPONSE" | jq -r '.job_id')
log "Job ID: ${JOB_ID}"

# ── Poll until terminal state ─────────────────────────────────────────────────
log "Polling /jobs/${JOB_ID} (initial wait: ${INITIAL_WAIT}s, interval: ${POLL_INTERVAL}s, timeout: ${SCAN_TIMEOUT}s)"
FINAL_STATE=""

log "Waiting ${INITIAL_WAIT}s before first poll…"
sleep "$INITIAL_WAIT"

DEADLINE=$(($(date +%s) + SCAN_TIMEOUT))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  RESPONSE=$(curl -sf "http://127.0.0.1:8000/jobs/${JOB_ID}" || echo '{"state":"error"}')
  STATE=$(echo "$RESPONSE" | jq -r '.state')
  log "[$(date -u +%H:%M:%S)] state: ${STATE}"
  if [ "$STATE" = "completed" ] || [ "$STATE" = "failed" ]; then
    FINAL_STATE="$STATE"
    echo "$RESPONSE" > /tmp/migratowl-result.json
    break
  fi
  sleep "$POLL_INTERVAL"
done

if [ -z "$FINAL_STATE" ]; then
  log "Timed out waiting for scan to complete — server log:" >&2
  cat /tmp/migratowl.log >&2
  exit 1
fi

if [ "$FINAL_STATE" = "failed" ]; then
  log "Scan failed: $(jq -r '.error' /tmp/migratowl-result.json)" >&2
  cat /tmp/migratowl.log >&2
  exit 1
fi

log "Scan completed"

# ── Handle results-destination ────────────────────────────────────────────────

case "$RESULTS_DESTINATION" in
  pr-comment)
    # Migratowl posts the PR comment itself when pr_number is provided.
    log "Results posted as PR comment by Migratowl server"
    ;;

  issue)
    ISSUE_BODY=$(python3 - /tmp/migratowl-result.json <<'PYEOF'
import sys, json

with open(sys.argv[1]) as f:
    data = json.load(f)

result = data.get('result', {}) or {}
reports = result.get('reports', []) or []
scan = result.get('scan_result', {}) or {}

lines = [
    "## Migratowl Dependency Scan Report",
    "",
    f"**Repository:** {result.get('repo_url', 'N/A')}  ",
    f"**Branch:** {result.get('branch_name', 'N/A')}  ",
    f"**Outdated dependencies found:** {len(scan.get('outdated', []))}  ",
    f"**Analyzed:** {len(reports)}",
    "",
]

if reports:
    lines += ["| Dependency | Breaking | Summary |", "|---|---|---|"]
    for r in reports:
        breaking = "⚠️ Yes" if r.get("is_breaking") else "✅ No"
        summary = r.get("error_summary", "").replace("|", "\\|")[:120]
        lines.append(f"| {r['dependency_name']} | {breaking} | {summary} |")
else:
    lines.append("No breaking changes detected.")

print("\n".join(lines))
PYEOF
)

    # Find existing open issue with label migratowl-report.
    EXISTING=$(gh issue list \
      --repo "$GITHUB_REPO" \
      --label migratowl-report \
      --state open \
      --json number \
      --jq '.[0].number' 2>/dev/null || echo "")

    if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
      log "Updating existing issue #${EXISTING}"
      gh issue edit "$EXISTING" --repo "$GITHUB_REPO" --body "$ISSUE_BODY"
    else
      log "Creating new issue with label migratowl-report"
      gh issue create \
        --repo "$GITHUB_REPO" \
        --title "Migratowl Dependency Scan Report" \
        --body  "$ISSUE_BODY" \
        --label migratowl-report
    fi
    ;;

  artifact)
    log "Results written to /tmp/migratowl-result.json (uploaded as workflow artifact)"
    ;;

  *)
    echo "Unknown results-destination: ${RESULTS_DESTINATION}" >&2
    exit 1
    ;;
esac

# Upload result regardless of destination so it's always inspectable.
cp /tmp/migratowl-result.json "${GITHUB_WORKSPACE}/migratowl-scan-result.json" 2>/dev/null || true

# ── fail-on-breaking check ────────────────────────────────────────────────────
if [ "$FAIL_ON_BREAKING" = "true" ]; then
  BREAKING=$(jq '[.result.reports // [] | .[] | select(.is_breaking == true)] | length' \
    /tmp/migratowl-result.json)
  if [ "$BREAKING" -gt 0 ]; then
    log "fail-on-breaking: ${BREAKING} breaking change(s) detected — failing step" >&2
    exit 1
  fi
fi

log "Done"
