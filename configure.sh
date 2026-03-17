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
OPENCLAW_CONTEXT_WINDOW="${OPENCLAW_CONTEXT_WINDOW:-128000}"

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

wait_for_tcp_port() {
  local port="$1"
  local timeout_secs="${2:-30}"
  local start_ts
  start_ts="$(date +%s)"

  while true; do
    if (echo >"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
      return 0
    fi

    if (( "$(date +%s)" - start_ts >= timeout_secs )); then
      return 1
    fi

    sleep 1
  done
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

get_gateway_token_from_config_file() {
  local config_file token

  config_file="$HOME/.openclaw/openclaw.json"
  [[ -f "$config_file" ]] || return 1

  if command -v jq >/dev/null 2>&1; then
    token="$(jq -r '.gateway.auth.token // empty' "$config_file" 2>/dev/null | sed -n '1p')" || true
  else
    token="$(node -e 'const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,"utf8"));if(j?.gateway?.auth?.token)process.stdout.write(j.gateway.auth.token);' "$config_file" 2>/dev/null)" || true
  fi

  [[ -n "$token" && "$token" != "__OPENCLAW_REDACTED__" && "$token" != "null" ]] || return 1
  printf '%s\n' "$token"
}

get_gateway_token_from_dashboard() {
  local dashboard_output token

  dashboard_output="$(openclaw dashboard --no-open 2>/dev/null || true)"
  token="$(printf '%s\n' "$dashboard_output" | sed -nE 's#.*[#?]token=([[:alnum:]]+).*#\1#p' | sed -n '1p')"
  [[ -n "$token" ]] || return 1
  printf '%s\n' "$token"
}

get_gateway_token() {
  local token

  if [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    printf '%s\n' "${OPENCLAW_GATEWAY_TOKEN}"
    return 0
  fi

  if token="$(get_gateway_token_from_config_file 2>/dev/null)"; then
    printf '%s\n' "$token"
    return 0
  fi

  if token="$(get_gateway_token_from_dashboard 2>/dev/null)"; then
    printf '%s\n' "$token"
    return 0
  fi

  set +e
  token="$(openclaw config get gateway.auth.token 2>/dev/null | sed -n '1p')"
  local status=$?
  set -e

  if [[ "$status" -eq 0 && -n "$token" && "$token" != "null" && "$token" != "undefined" && "$token" != "__OPENCLAW_REDACTED__" ]]; then
    printf '%s\n' "$token"
    return 0
  fi

  return 1
}

start_gateway() {
  local gateway_log="$1"
  local pid_file="$2"
  local config_file gateway_port

  if [[ -f "$pid_file" ]]; then
    local existing_pid
    existing_pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      printf '%s\n' "$existing_pid"
      return 0
    fi
  fi

  config_file="$HOME/.openclaw/openclaw.json"
  gateway_port="18789"
  if [[ -f "$config_file" ]]; then
    if command -v jq >/dev/null 2>&1; then
      gateway_port="$(jq -r '.gateway.port // 18789' "$config_file" 2>/dev/null | sed -n '1p')" || gateway_port="18789"
    fi
  fi

  nohup openclaw gateway >"$gateway_log" 2>&1 &
  local gateway_pid=$!
  printf '%s\n' "$gateway_pid" >"$pid_file"

  sleep 3
  kill -0 "$gateway_pid" 2>/dev/null || fail "OpenClaw gateway exited early. Check $gateway_log"
  wait_for_tcp_port "$gateway_port" 30 || fail "OpenClaw gateway did not open port ${gateway_port}. Check $gateway_log"
  printf '%s\n' "$gateway_pid"
}

stop_existing_gateway() {
  local pid_file="$1"

  if [[ ! -f "$pid_file" ]]; then
    return 0
  fi

  local existing_pid
  existing_pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
  if [[ -z "$existing_pid" ]]; then
    rm -f "$pid_file"
    return 0
  fi

  if kill -0 "$existing_pid" 2>/dev/null; then
    log "Stopping previously launched gateway process ${existing_pid}"
    kill "$existing_pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$existing_pid" 2>/dev/null; then
      kill -9 "$existing_pid" 2>/dev/null || true
    fi
  fi

  rm -f "$pid_file"
}

start_auto_approve_loop() {
  local approval_log="$1"
  (
    local end_time now pending_count
    end_time=$(( $(date +%s) + 1200 ))

    while true; do
      now="$(date +%s)"
      if [[ "$now" -ge "$end_time" ]]; then
        exit 0
      fi

      if openclaw devices list --json >"$approval_log.tmp" 2>&1; then
        if command -v jq >/dev/null 2>&1; then
          pending_count="$(jq -r '.pending | length' "$approval_log.tmp" 2>/dev/null || printf '0')"
        else
          pending_count="$(node -e 'const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,"utf8"));process.stdout.write(String(Array.isArray(j.pending)?j.pending.length:0));' "$approval_log.tmp" 2>/dev/null || printf '0')"
        fi

        if [[ "$pending_count" =~ ^[0-9]+$ ]] && [[ "$pending_count" -gt 0 ]]; then
          openclaw devices approve --latest >>"$approval_log" 2>&1 || true
        fi
      fi

      cat "$approval_log.tmp" >>"$approval_log" 2>/dev/null || true
      rm -f "$approval_log.tmp"
      sleep 1
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

configure_control_ui_origin() {
  local origin
  local origins_json

  origin="$(derive_openclaw_origin)"
  origins_json="$(cat <<EOF
["http://127.0.0.1:18789","http://localhost:18789","${origin}"]
EOF
)"

  log "Setting OpenClaw Control UI allowedOrigins to ${origins_json}"
  openclaw config set gateway.controlUi.allowedOrigins "$origins_json" --strict-json >/dev/null
}

print_gateway_info() {
  local token="$1"
  local host_name origin url

  host_name="$(hostname 2>/dev/null || true)"
  origin="$(derive_openclaw_origin)"
  if [[ -n "$token" ]]; then
    url="${origin}/#token=${token}"
  else
    url="${origin}/chat?session=main"
  fi

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

set_model_context_window() {
  local config_file tmp_file

  config_file="$HOME/.openclaw/openclaw.json"
  [[ -f "$config_file" ]] || fail "OpenClaw config not found: $config_file"

  tmp_file="$(mktemp "$config_file.tmp.XXXXXX")"
  jq --arg model_id "$OPENCLAW_MODEL" --argjson context_window "$OPENCLAW_CONTEXT_WINDOW" '
    .models.providers |= with_entries(
      if (.value.models | type?) == "array" then
        .value.models |= map(
          if .id == $model_id then
            .contextWindow = $context_window
          else
            .
          end
        )
      else
        .
      end
    )
  ' "$config_file" >"$tmp_file"
  mv "$tmp_file" "$config_file"
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
    set_model_context_window
    write_env_file
  else
    log "OpenClaw is already configured; skipping onboarding"
    load_saved_env
  fi

  configure_control_ui_origin

  token="$(get_gateway_token || true)"
  if [[ -z "$token" ]]; then
    log "No configured gateway token found; generating one with OpenClaw doctor"
    openclaw doctor --generate-gateway-token >/dev/null
    token="$(get_gateway_token || true)"
  fi

  stop_existing_gateway "$pid_file"
  log "Starting OpenClaw gateway"
  gateway_pid="$(start_gateway "$gateway_log" "$pid_file")"
  log "Gateway is running with PID $gateway_pid"
  log "Starting 20-minute auto-approval loop"
  start_auto_approve_loop "$approval_log"
  print_gateway_info "$token"
}

main "$@"
