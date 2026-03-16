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
OPENCLAW_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/openclaw-bootstrap"

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

get_gateway_token() {
  local token

  if [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    printf '%s\n' "${OPENCLAW_GATEWAY_TOKEN}"
    return 0
  fi

  set +e
  token="$(openclaw config get gateway.auth.token 2>/dev/null | sed -n '1p')"
  local status=$?
  set -e

  if [[ "$status" -eq 0 && -n "$token" && "$token" != "null" && "$token" != "undefined" ]]; then
    printf '%s\n' "$token"
    return 0
  fi

  return 1
}

start_gateway() {
  local gateway_log="$1"
  local pid_file="$2"

  if [[ -f "$pid_file" ]]; then
    local existing_pid
    existing_pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      printf '%s\n' "$existing_pid"
      return 0
    fi
  fi

  nohup openclaw gateway >"$gateway_log" 2>&1 &
  local gateway_pid=$!
  printf '%s\n' "$gateway_pid" >"$pid_file"

  sleep 3
  kill -0 "$gateway_pid" 2>/dev/null || fail "OpenClaw gateway exited early. Check $gateway_log"
  printf '%s\n' "$gateway_pid"
}

start_auto_approve_loop() {
  local approval_log="$1"
  (
    local end_time now device_ids device_id
    end_time=$(( $(date +%s) + 1200 ))

    while true; do
      now="$(date +%s)"
      if [[ "$now" -ge "$end_time" ]]; then
        exit 0
      fi

      if openclaw devices list >"$approval_log.tmp" 2>&1; then
        device_ids="$(
          grep -Eo '[[:alnum:]_-]{6,}' "$approval_log.tmp" | awk '!seen[$0]++'
        )"
        for device_id in $device_ids; do
          openclaw devices approve "$device_id" >>"$approval_log" 2>&1 || true
        done
      fi

      cat "$approval_log.tmp" >>"$approval_log" 2>/dev/null || true
      rm -f "$approval_log.tmp"
      sleep 5
    done
  ) >/dev/null 2>&1 &
}

derive_openclaw_origin() {
  local host_name env_id
  host_name="$(hostname 2>/dev/null || true)"
  env_id="$(printf '%s\n' "$host_name" | sed -E 's/^brev-([[:alnum:]]+)$/\1/')"

  if [[ -n "$env_id" && "$env_id" != "$host_name" ]]; then
    printf 'https://openclaw0-%s.brevlab.com\n' "$env_id"
  else
    printf 'http://localhost:3000\n'
  fi
}

print_gateway_info() {
  local token="$1"
  local host_name origin url

  host_name="$(hostname 2>/dev/null || true)"
  origin="$(derive_openclaw_origin)"
  url="${origin}/chat?session=main"

  printf '\nOpenClaw Gateway Started\n'
  printf '========================\n\n'
  printf 'URL:\n%s\n\n' "$url"
  printf 'API Token:\n%s\n\n' "${token:-Unavailable - review $OPENCLAW_STATE_DIR/gateway.log}"
  printf 'Hostname:\n%s\n\n' "${host_name:-unknown}"
  printf 'Origin:\n%s\n' "$origin"
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
  local gateway_log approval_log pid_file token gateway_pid

  append_path_if_dir "$HOME/.npm-global/bin"
  append_path_if_dir "$HOME/.local/bin"
  append_path_if_dir "$HOME/bin"
  command -v openclaw >/dev/null 2>&1 || fail "OpenClaw CLI is not installed. Run launch.sh first."

  mkdir -p "$OPENCLAW_STATE_DIR"
  gateway_log="$OPENCLAW_STATE_DIR/gateway.log"
  approval_log="$OPENCLAW_STATE_DIR/auto-approve.log"
  pid_file="$OPENCLAW_STATE_DIR/gateway.pid"

  if ! is_openclaw_configured; then
    if has_saved_key; then
      log "Using saved NVIDIA API key from $OPENCLAW_ENV_FILE"
      load_saved_env
    else
      prompt_for_nvidia_key
    fi

    [[ -n "${CUSTOM_API_KEY:-}" ]] || fail "CUSTOM_API_KEY is not available"
    run_noninteractive_onboarding
    write_env_file
  else
    log "OpenClaw is already configured; skipping onboarding"
    load_saved_env
  fi

  token="$(get_gateway_token || true)"
  if [[ -z "$token" ]]; then
    log "No configured gateway token found; generating one with OpenClaw doctor"
    openclaw doctor --generate-gateway-token >/dev/null
    token="$(get_gateway_token || true)"
  fi

  log "Starting OpenClaw gateway"
  gateway_pid="$(start_gateway "$gateway_log" "$pid_file")"
  log "Gateway is running with PID $gateway_pid"
  log "Starting 20-minute auto-approval loop"
  start_auto_approve_loop "$approval_log"
  print_gateway_info "$token"
}

main "$@"
