#!/usr/bin/env bash
# Sourced by start-migratowl.sh: maps the model-provider, llm-base-url and
# model-alias inputs onto the environment variables the Migratowl server reads.
# Keep in sync with templates/scan.yml in bitkaio/migratowl-gitlab-component.

PROVIDER="${MODEL_PROVIDER_INPUT:-}"
if [ -z "$PROVIDER" ]; then
  # Default: OpenAI when its key is the one supplied, otherwise Anthropic.
  if [ -n "${OPENAI_API_KEY:-}" ]; then PROVIDER=openai; else PROVIDER=anthropic; fi
fi
case "$PROVIDER" in
  anthropic|openai|litellm) ;;
  *) echo "[migratowl] model-provider must be anthropic, openai or litellm (got '$PROVIDER')" >&2; exit 1 ;;
esac
export MIGRATOWL_MODEL_PROVIDER="$PROVIDER"

if [ -n "${LLM_BASE_URL:-}" ]; then
  case "$PROVIDER" in
    anthropic) export ANTHROPIC_BASE_URL="$LLM_BASE_URL" ;;
    openai)    export OPENAI_BASE_URL="$LLM_BASE_URL" ;;
    litellm)   export LITELLM_BASE_URL="$LLM_BASE_URL" ;;
  esac
fi

if [ -n "${MODEL_ALIAS:-}" ]; then
  export MIGRATOWL_MODEL_ALIAS="$MODEL_ALIAS"
fi
