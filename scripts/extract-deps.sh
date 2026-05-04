#!/usr/bin/env bash
# Determines scan eligibility and extracts targeted deps from PR context.
#
# Outputs (written to $GITHUB_ENV):
#   MIGRATOWL_SKIP=true|false
#   MIGRATOWL_CHECK_DEPS=JSON array of package names ([] = full scan)

set -euo pipefail

SCAN_TRIGGER="${SCAN_TRIGGER:-bot}"
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
PR_NUMBER="${PR_NUMBER:-}"
CHECK_DEPS_OVERRIDE="${CHECK_DEPS_OVERRIDE:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
BASE_BRANCH="${BASE_BRANCH:-}"
HEAD_BRANCH="${HEAD_BRANCH:-}"

# ── Helpers ──────────────────────────────────────────────────────────────────

log() { echo "[migratowl] $*"; }

# Fetch PR data from GitHub API and populate PR_AUTHOR, PR_TITLE, PR_BODY, PR_BRANCH.
fetch_pr_data() {
  if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
    PR_AUTHOR=""
    PR_TITLE=""
    PR_BODY=""
    PR_BRANCH=""
    return
  fi
  local pr_json
  pr_json=$(gh api "repos/${GITHUB_REPO}/pulls/${PR_NUMBER}" 2>/dev/null || echo "{}")
  PR_AUTHOR=$(echo "$pr_json" | jq -r '.user.login // ""')
  PR_TITLE=$(echo "$pr_json"  | jq -r '.title // ""')
  PR_BODY=$(echo "$pr_json"   | jq -r '.body // ""')
  PR_BRANCH=$(echo "$pr_json" | jq -r '.head.ref // ""')
}

is_bot_pr() {
  case "$PR_AUTHOR" in
    "dependabot[bot]"|"renovate[bot]") return 0 ;;
    *) return 1 ;;
  esac
}

# Returns 0 if any recognised dependency manifest was changed in this PR.
dep_manifests_changed() {
  local manifests="package.json requirements.txt pyproject.toml go.mod Cargo.toml pom.xml build.gradle"
  local changed
  changed=$(gh api "repos/${GITHUB_REPO}/pulls/${PR_NUMBER}/files" \
    --paginate --jq '[.[].filename]' 2>/dev/null | jq -r '.[]' || echo "")
  for manifest in $manifests; do
    if echo "$changed" | grep -qF "$manifest"; then
      return 0
    fi
  done
  return 1
}

# Extracts bumped package names from a Dependabot PR.
extract_dependabot_deps() {
  local dep=""
  # Title pattern: "Bump <pkg> from <old> to <new>" or "chore(deps): bump <pkg> from ..."
  dep=$(echo "$PR_TITLE" | sed -n 's/.*[Bb]ump \([^ ]*\) from .*/\1/p' | head -1)
  if [ -z "$dep" ]; then
    # Branch pattern: dependabot/<ecosystem>/<pkg>-<version>
    dep=$(echo "$PR_BRANCH" | sed -n 's|dependabot/[^/]*/\(.*\)-[0-9][0-9.]*$|\1|p')
  fi
  if [ -n "$dep" ]; then
    jq -n --arg d "$dep" '[$d]'
  else
    echo "[]"
  fi
}

# Extracts bumped package names from a Renovate PR (single-dep or grouped).
extract_renovate_deps() {
  # 1. Try parsing the markdown table in the PR body.
  #    Renovate tables start with a "| Package |" header row.
  local table_deps
  table_deps=$(python3 - "$PR_BODY" <<'PYEOF'
import sys, re, json

body = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read()
deps = []
in_table = False
for line in body.splitlines():
    s = line.strip()
    if re.match(r'\|\s*Package\s*\|', s):
        in_table = True
        continue
    if in_table and re.match(r'\|[-\s|]+\|', s):
        continue
    if in_table and s.startswith('|'):
        first_col = s.split('|')[1].strip()
        # Strip markdown link: [text](url) -> text
        first_col = re.sub(r'\[([^\]]+)\]\([^)]*\)', r'\1', first_col).strip()
        if first_col and not re.match(r'^-+$', first_col):
            deps.append(first_col)
    elif in_table:
        break
print(json.dumps(deps))
PYEOF
)
  if [ "$table_deps" != "[]" ] && [ -n "$table_deps" ]; then
    echo "$table_deps"
    return 0
  fi

  # 2. Try title parsing for single-dep Renovate PRs.
  #    Typical: "chore(deps): update <package> to v<version>"
  local dep=""
  dep=$(echo "$PR_TITLE" | sed -n 's/.*[Uu]pdate[[:space:]]\+\([^[:space:]]*\)[[:space:]].*/\1/p' | head -1)
  if [ -n "$dep" ]; then
    jq -n --arg d "$dep" '[$d]'
    return 0
  fi

  # 3. Grouped update — couldn't parse specific packages; signal full scan.
  echo "::notice::Renovate grouped PR detected — dep table not found or unparseable, running full scan"
  echo "[]"
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Scheduled triggers always run a full scan; skip trigger evaluation entirely.
if [ "$EVENT_NAME" = "schedule" ]; then
  log "Scheduled trigger — full scan"
  echo "MIGRATOWL_SKIP=false"             >> "$GITHUB_ENV"
  echo "MIGRATOWL_CHECK_DEPS=[]"          >> "$GITHUB_ENV"
  echo "MIGRATOWL_BRANCH=${HEAD_BRANCH}"  >> "$GITHUB_ENV"
  exit 0
fi

fetch_pr_data

# Evaluate scan-trigger policy.
case "$SCAN_TRIGGER" in
  bot)
    if ! is_bot_pr; then
      log "scan-trigger: bot — skipping human-authored PR (author: ${PR_AUTHOR:-unknown})"
      echo "MIGRATOWL_SKIP=true" >> "$GITHUB_ENV"
      exit 0
    fi
    ;;
  deps-changed)
    if ! is_bot_pr; then
      if ! dep_manifests_changed; then
        log "scan-trigger: deps-changed — no dependency manifests modified, skipping"
        echo "MIGRATOWL_SKIP=true" >> "$GITHUB_ENV"
        exit 0
      fi
      log "scan-trigger: deps-changed — dep manifest changed, running full scan"
      echo "MIGRATOWL_SKIP=false"    >> "$GITHUB_ENV"
      echo "MIGRATOWL_CHECK_DEPS=[]" >> "$GITHUB_ENV"
      exit 0
    fi
    ;;
  always)
    : # Never skip
    ;;
  *)
    echo "Unknown scan-trigger value: ${SCAN_TRIGGER}" >&2
    exit 1
    ;;
esac

echo "MIGRATOWL_SKIP=false" >> "$GITHUB_ENV"

# Bot PRs: scan BASE branch — dep is already bumped on HEAD, scanning HEAD would
# show it as "already at latest" and skip it. Scanning BASE lets migratowl upgrade
# from the old version and detect test failures.
# Human PRs: scan HEAD — test the actual submitted code against upgraded deps.
if is_bot_pr; then
  echo "MIGRATOWL_BRANCH=${BASE_BRANCH}" >> "$GITHUB_ENV"
else
  echo "MIGRATOWL_BRANCH=${HEAD_BRANCH}" >> "$GITHUB_ENV"
fi

# User-provided override takes precedence over auto-extraction.
if [ -n "$CHECK_DEPS_OVERRIDE" ]; then
  CHECK_DEPS=$(echo "$CHECK_DEPS_OVERRIDE" | python3 -c \
    "import sys,json; s=sys.stdin.read().strip(); print(json.dumps([x.strip() for x in s.split(',') if x.strip()]))")
  log "check-deps override: ${CHECK_DEPS}"
  echo "MIGRATOWL_CHECK_DEPS=${CHECK_DEPS}" >> "$GITHUB_ENV"
  exit 0
fi

# Auto-extract from bot PR context.
if is_bot_pr; then
  case "$PR_AUTHOR" in
    "dependabot[bot]")
      CHECK_DEPS=$(extract_dependabot_deps)
      ;;
    "renovate[bot]")
      CHECK_DEPS=$(extract_renovate_deps)
      ;;
    *)
      CHECK_DEPS="[]"
      ;;
  esac
  log "Auto-extracted check_deps: ${CHECK_DEPS}"
  echo "MIGRATOWL_CHECK_DEPS=${CHECK_DEPS}" >> "$GITHUB_ENV"
else
  log "Human-authored PR on scan-trigger: ${SCAN_TRIGGER} — full scan"
  echo "MIGRATOWL_CHECK_DEPS=[]" >> "$GITHUB_ENV"
fi
