#!/usr/bin/env bash
# Runs scripts/extract-deps.sh against a fake `gh` and checks what it writes to $GITHUB_ENV.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"/files"*) echo '[{"filename":"package.json"}]' ;;
  *) echo '{"user":{"login":"some-human"},"title":"Bump eslint","body":"","head":{"ref":"feature-branch"}}' ;;
esac
GH
chmod +x "$tmp/bin/gh"
fail=0
run() { # name, expected substring, env...
  local name=$1 expect=$2; shift 2
  : > "$tmp/env"
  env PATH="$tmp/bin:$PATH" GITHUB_ENV="$tmp/env" GITHUB_EVENT_NAME=pull_request GITHUB_REPO=o/r PR_NUMBER=1 \
      BASE_BRANCH=main HEAD_BRANCH=feature-branch "$@" bash scripts/extract-deps.sh >/dev/null
  if grep -qF "$expect" "$tmp/env"; then echo "ok   $name"; else echo "FAIL $name: expected '$expect' in:"; sed 's/^/       /' "$tmp/env"; fail=1; fi
}
run "deps-changed on a human PR scans the head branch" "MIGRATOWL_BRANCH=feature-branch" SCAN_TRIGGER=deps-changed
run "deps-changed honours check-deps" 'MIGRATOWL_CHECK_DEPS=["eslint"]' SCAN_TRIGGER=deps-changed CHECK_DEPS_OVERRIDE=eslint
run "always on a human PR scans the head branch" "MIGRATOWL_BRANCH=feature-branch" SCAN_TRIGGER=always
exit $fail
