#!/usr/bin/env bash
set -euo pipefail

SOURCE_PATH="${BASH_SOURCE[0]-}"
if [[ -z "$SOURCE_PATH" || "$SOURCE_PATH" == "bash" || "$SOURCE_PATH" == "-bash" ]]; then
  SCRIPT_DIR="$PWD"
else
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
fi

OPENCLAW_ENV_DIR="${OPENCLAW_ENV_DIR:-$HOME/.openclaw}"
OPENCLAW_ENV_FILE="${OPENCLAW_ENV_FILE:-$OPENCLAW_ENV_DIR/.env}"
OPENCLAW_MODEL="${OPENCLAW_MODEL:-nvidia/nemotron-3-super-120b-a12b}"
OPENCLAW_BASE_URL="${OPENCLAW_BASE_URL:-https://integrate.api.nvidia.com/v1}"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

append_path_if_dir() {
  local dir="$1"
  if [[ -d "$dir" && ":$PATH:" != *":$dir:"* ]]; then
    export PATH="$dir:$PATH"
  fi
}

has_saved_key() {
  [[ -f "$OPENCLAW_ENV_FILE" ]] && grep -q '^CUSTOM_API_KEY=' "$OPENCLAW_ENV_FILE"
}

is_openclaw_configured() {
  has_saved_key && [[ -f "$HOME/.openclaw/openclaw.json" ]]
}

load_saved_env() {
  if [[ -f "$OPENCLAW_ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$OPENCLAW_ENV_FILE"
    set +a
  fi
}

prompt_for_nvidia_key() {
  local entered

  printf '\nOpenClaw needs an NVIDIA API key for the initial model route.\n'
  printf 'Provider: OpenAI-compatible NVIDIA Integrate\n'
  printf 'Base URL: %s\n' "$OPENCLAW_BASE_URL"
  printf 'Model: %s\n\n' "$OPENCLAW_MODEL"

  read -r -s -p "Enter NVIDIA API Key: " entered
  printf '\n'
  [[ -n "$entered" ]] || fail "A non-empty NVIDIA API key is required"
  CUSTOM_API_KEY="$entered"
  export CUSTOM_API_KEY
}

write_env_file() {
  local tmp_env

  mkdir -p "$OPENCLAW_ENV_DIR"
  tmp_env="$(mktemp "$OPENCLAW_ENV_DIR/.env.XXXXXX")"
  chmod 600 "$tmp_env"
  {
    printf 'CUSTOM_API_KEY=%q\n' "$CUSTOM_API_KEY"
    printf 'NVIDIA_API_KEY=%q\n' "$CUSTOM_API_KEY"
  } >"$tmp_env"
  mv "$tmp_env" "$OPENCLAW_ENV_FILE"
  chmod 600 "$OPENCLAW_ENV_FILE"
}

run_noninteractive_onboarding() {
  log "Running non-interactive OpenClaw onboarding"
  openclaw onboard \
    --non-interactive \
    --accept-risk \
    --mode local \
    --no-install-daemon \
    --skip-skills \
    --skip-health \
    --auth-choice custom-api-key \
    --custom-base-url "$OPENCLAW_BASE_URL" \
    --custom-model-id "$OPENCLAW_MODEL" \
    --custom-api-key CUSTOM_API_KEY \
    --secret-input-mode ref \
    --custom-compatibility openai
}

main() {
  append_path_if_dir "$HOME/.npm-global/bin"
  append_path_if_dir "$HOME/.local/bin"
  append_path_if_dir "$HOME/bin"
  command -v openclaw >/dev/null 2>&1 || fail "OpenClaw CLI is not installed. Run launch.sh first."

  if is_openclaw_configured; then
    log "OpenClaw is already configured; starting the normal launch flow"
    exec "$SCRIPT_DIR/launch.sh"
  fi

  if has_saved_key; then
    log "Using saved NVIDIA API key from $OPENCLAW_ENV_FILE"
    load_saved_env
  else
    prompt_for_nvidia_key
  fi

  [[ -n "${CUSTOM_API_KEY:-}" ]] || fail "CUSTOM_API_KEY is not available"
  run_noninteractive_onboarding
  write_env_file

  log "OpenClaw configuration complete; re-running launch.sh without code-server bootstrap"
  exec env OPENCLAW_BOOTSTRAP_SKIP_CODE_SERVER=1 "$SCRIPT_DIR/launch.sh"
}

main "$@"
