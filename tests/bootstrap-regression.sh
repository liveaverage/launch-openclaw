#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
passes=0

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
    node() { printf 'v22.23.3\n'; }
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
