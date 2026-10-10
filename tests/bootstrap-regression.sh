#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
passes=0

for runtime in v22.23.3 v24.15.9 v24.16.0 v24.21.0 v24.16.0-rc.1 v25.0.0 v26.0.9 v26.1.0 v27.0.0 unavailable; do
  (
    eval "$(sed '$d' "$ROOT/launch.sh")"
    node() { printf '%s\n' "$runtime"; }
    case "$runtime" in
      v24.16.0|v24.21.0|v26.1.0|v27.0.0) node_runtime_supported ;;
      *) ! node_runtime_supported ;;
    esac
  )
  passes=$((passes + 1))
done

(
  unset OPENCLAW_VERSION OPENCLAW_RELEASE_TAG
  eval "$(sed '$d' "$ROOT/launch.sh")"
  [[ "$DEFAULT_OPENCLAW_VERSION" == 2026.9.9 && "$OPENCLAW_RELEASE_TAG" == v2026.9.9 ]]
)
passes=$((passes + 1))

for migration in valid repaired unrepairable; do
  (
    eval "$(sed '$d' "$ROOT/configure.sh")"
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT
    HOME="$fixture"
    mkdir -p "$HOME/.openclaw"
    cp "$ROOT/README.md" "$HOME/.openclaw/openclaw.json"
    validates=0
    repairs=0
    openclaw() {
      if [[ "$1 $2" == 'config validate' ]]; then
        validates=$((validates + 1))
        [[ "$migration" == valid || ( "$migration" == repaired && "$validates" -gt 1 ) ]]
      else
        [[ "$*" == 'doctor --fix --non-interactive' ]]
        repairs=$((repairs + 1))
      fi
    }
    if [[ "$migration" == unrepairable ]]; then
      if (ensure_config_compatible); then
        exit 1
      fi
    else
      ensure_config_compatible
      if [[ "$migration" == valid ]]; then
        [[ "$repairs" -eq 0 ]]
      else
        [[ "$repairs" -eq 1 && "$validates" -eq 2 ]]
      fi
    fi
    if [[ "$migration" != valid ]]; then
      for backup in "$HOME"/.openclaw/openclaw.json.pre-migration.*; do
        cmp -s "$backup" "$HOME/.openclaw/openclaw.json"
        [[ "$(ls -l "$backup" | awk '{print substr($1,1,10)}')" == '-rw-------' ]]
      done
    fi
  )
  passes=$((passes + 1))
done

for proxies in '["100.73.87.46"]' '["127.0.0.1","::1"]' '["0.0.0.0/0"]' '["100.64.0.0/10"]' '["*"]' '["0.0.0.0"]' '["::"]' '[]' 'not-json'; do
  (
    eval "$(sed '$d' "$ROOT/configure.sh")"
    OPENCLAW_TRUSTED_PROXY_IPS="$proxies"
    openclaw() {
      [[ "$1 $2 $3" == 'config set gateway.trustedProxies' && "$4" == "$proxies" && "$5" == --strict-json ]]
    }
    case "$proxies" in
      '["100.73.87.46"]'|'["127.0.0.1","::1"]') configure_trusted_proxies ;;
      *) if (configure_trusted_proxies >/dev/null 2>&1); then exit 1; fi ;;
    esac
  )
  passes=$((passes + 1))
done

for credential in literal reference missing; do
  (
    eval "$(sed '$d' "$ROOT/configure.sh")"
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT
    HOME="$fixture"
    unset OPENCLAW_GATEWAY_TOKEN
    mkdir -p "$HOME/.openclaw"
    case "$credential" in
      literal) printf '%s' '{"gateway":{"auth":{"token":"qa-fake-token"}}}' > "$HOME/.openclaw/openclaw.json" ;;
      reference) printf '%s' '{"gateway":{"auth":{"token":{"source":"store","provider":"default","id":"gateway-token"}}}}' > "$HOME/.openclaw/openclaw.json" ;;
      missing) printf '%s' '{"gateway":{"auth":{}}}' > "$HOME/.openclaw/openclaw.json" ;;
    esac
    if [[ "$credential" == missing ]]; then
      ! gateway_token_is_configured
    else
      gateway_token_is_configured
    fi
    if [[ "$credential" == literal ]]; then
      [[ "$(get_gateway_token_from_config_file)" == qa-fake-token ]]
    else
      ! get_gateway_token_from_config_file
    fi
  )
  passes=$((passes + 1))
done

(
  eval "$(sed '$d' "$ROOT/configure.sh")"
  hostname() { printf 'brev-u1x29ihj3\n'; }
  openclaw() {
    [[ "$*" == 'dashboard --no-open --json' ]]
    printf '%s' '{"ok":true,"browserUrl":"http://127.0.0.1:18789/#bootstrapToken=qa-fake-bootstrap&bootstrapProfile=main&gatewayUrl=ws%3A%2F%2F127.0.0.1%3A18789"}'
  }
  url="$(get_dashboard_connection_url)"
  node -e '
    const url=new URL(process.argv[1]); const params=new URLSearchParams(url.hash.slice(1));
    if(url.origin!=="https://openclaw-u1x29ihj3.gobrev.dev" || params.get("bootstrapToken")!=="qa-fake-bootstrap" || params.get("gatewayUrl")!=="wss://openclaw-u1x29ihj3.gobrev.dev/") process.exit(1);
  ' "$url"
)
passes=$((passes + 1))

check_origin() (
  local script="$1" function="$2" host="$3" expected="$4" override="${5:-}"
  # Load function definitions without invoking the script's final main call.
  eval "$(sed '$d' "$ROOT/$script")"
  hostname() { printf '%s\n' "$host"; }
  unset OPENCLAW_ORIGIN CODE_SERVER_ORIGIN
  if [[ "$function" == derive_openclaw_origin ]]; then
    OPENCLAW_ORIGIN="$override"
  else
    CODE_SERVER_ORIGIN="$override"
  fi
  [[ "$("$function")" == "$expected" ]]
)

for script in launch.sh configure.sh; do
  check_origin "$script" derive_openclaw_origin brev-u1x29ihj3 https://openclaw-u1x29ihj3.gobrev.dev
  check_origin "$script" derive_openclaw_origin local-dev http://localhost:18789
  check_origin "$script" derive_openclaw_origin brev-u1x29ihj3 https://custom.example https://custom.example/
  passes=$((passes + 3))
done
check_origin launch.sh derive_code_server_origin brev-u1x29ihj3 https://code-server-u1x29ihj3.gobrev.dev
check_origin launch.sh derive_code_server_origin local-dev http://localhost:13337
check_origin launch.sh derive_code_server_origin brev-u1x29ihj3 https://editor.example https://editor.example/
passes=$((passes + 3))

(
  eval "$(sed '$d' "$ROOT/configure.sh")"
  hostname() { printf 'brev-u1x29ihj3\n'; }
  openclaw() {
    if [[ "$3" == gateway.bind ]]; then
      [[ "$4" == lan ]]
    else
      [[ "$3" == gateway.controlUi.allowedOrigins && "$5" == --strict-json ]]
      node -e '
        const origins=JSON.parse(process.argv[1]);
        for(const origin of ["https://openclaw-u1x29ihj3.gobrev.dev", "https://openclaw-u1x29ihj3.apps.run.brev.nvidia.com", "https://openclaw-u1x29ihj3.stg.apps.launchpad.nvidia.com"]) {
          if(!origins.includes(origin)) process.exit(1);
        }
        if(origins.includes("*")) process.exit(1);
      ' "$4"
    fi
  }
  configure_control_ui_origin
)
passes=$((passes + 1))

for configured in yes no; do
  (
    eval "$(sed '$d' "$ROOT/launch.sh")"
    calls=""
    for function in require_non_root require_cmd ensure_node ensure_openclaw_installed verify_openclaw_cli clone_or_refresh_launch_repo install_code_server install_code_server_extensions configure_code_server enable_code_server_service; do
      eval "$function() { :; }"
    done
    node() { printf 'v24.21.0\n'; }
    is_openclaw_configured() { [[ "$configured" == yes ]]; }
    bash() { calls="${calls}gateway "; [[ "$1" == "$LAUNCH_REPO_DIR/configure.sh" ]]; }
    print_configuration_pending() { calls="${calls}pending "; }
    main
    if [[ "$configured" == yes ]]; then
      [[ "$calls" == 'gateway ' ]]
    else
      [[ "$calls" == 'pending ' ]]
    fi
  )
  passes=$((passes + 1))
done

printf 'PASS: %s bootstrap regression cases\n' "$passes"
