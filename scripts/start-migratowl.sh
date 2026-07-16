#!/usr/bin/env bash
# Checks out bitkaio/migratowl at the requested version, installs it with uv,
# and starts the uvicorn API server on 127.0.0.1:8000 in the background.

set -euo pipefail

MIGRATOWL_VERSION="${MIGRATOWL_VERSION:-latest}"
MIGRATOWL_DIR="${RUNNER_TEMP}/migratowl"

log() { echo "[migratowl/start-migratowl] $*"; }

# ── Resolve version tag ───────────────────────────────────────────────────────
if [ "$MIGRATOWL_VERSION" = "latest" ]; then
  GIT_REF="main"
else
  GIT_REF="$MIGRATOWL_VERSION"
fi

# ── Clone server source ───────────────────────────────────────────────────────
log "Cloning bitkaio/migratowl @ ${GIT_REF}"
git clone --depth=1 --branch "$GIT_REF" \
  https://github.com/bitkaio/migratowl.git \
  "$MIGRATOWL_DIR"

# ── Install uv if not present ─────────────────────────────────────────────────
if ! command -v uv &>/dev/null; then
  log "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:$PATH"
  echo "${HOME}/.local/bin" >> "$GITHUB_PATH"
fi

# ── Install dependencies ──────────────────────────────────────────────────────
log "Installing dependencies"
uv sync --frozen --directory "$MIGRATOWL_DIR"

# ── Determine model provider from supplied keys ───────────────────────────────
if [ -n "${OPENAI_API_KEY:-}" ]; then
  export MIGRATOWL_MODEL_PROVIDER=openai
else
  export MIGRATOWL_MODEL_PROVIDER=anthropic
fi

# ── Start server in background ────────────────────────────────────────────────
log "Starting Migratowl server"
env \
  MIGRATOWL_SANDBOX_MODE=raw \
  MIGRATOWL_SANDBOX_IMAGE="${MIGRATOWL_RUNTIME_IMAGE:-ghcr.io/bitkaio/migratowl-runtime:latest}" \
  MIGRATOWL_SANDBOX_BLOCK_NETWORK=true \
  MIGRATOWL_MODEL_PROVIDER="$MIGRATOWL_MODEL_PROVIDER" \
  MIGRATOWL_MODEL_NAME="${MIGRATOWL_MODEL_NAME:-claude-sonnet-5}" \
  MIGRATOWL_CONFIDENCE_THRESHOLD="${MIGRATOWL_CONFIDENCE_THRESHOLD:-0.7}" \
  ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
  OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
  GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
  uv run --directory "$MIGRATOWL_DIR" \
    uvicorn migratowl.api.main:app \
    --host 127.0.0.1 --port 8000 \
    > /tmp/migratowl.log 2>&1 &

echo $! > /tmp/migratowl.pid
log "Server PID: $(cat /tmp/migratowl.pid)"

# ── Wait for server to be ready ───────────────────────────────────────────────
log "Waiting for /healthz"
for i in $(seq 1 60); do
  if curl -sf http://127.0.0.1:8000/healthz > /dev/null 2>&1; then
    log "Server ready (attempt ${i})"
    exit 0
  fi
  sleep 2
done

echo "[migratowl/start-migratowl] Server did not become ready — dumping log:" >&2
cat /tmp/migratowl.log >&2
exit 1
