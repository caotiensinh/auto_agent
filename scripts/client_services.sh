#!/usr/bin/env bash
set -Eeuo pipefail
AUTO_AGENT_COMPONENT=client-services

HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
LAN_CONTROL="${LAN_CONTROL:-0}"
CONTROL_DIR="$HOME/.config/auto_agent"
CONTROL_ENV="$CONTROL_DIR/control.env"
HERMES_DASHBOARD_UNIT="auto-agent-hermes-dashboard.service"

log(){ printf '\033[1;34m[CLIENT-SVC]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[CLIENT-SVC:OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CLIENT-SVC:WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[CLIENT-SVC:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run as normal Ubuntu user, not root"
command -v sudo >/dev/null 2>&1 || die "sudo is required"
command -v systemctl >/dev/null 2>&1 || die "systemctl is required"
command -v loginctl >/dev/null 2>&1 || die "loginctl is required"

prepare_path(){
  local d found=""
  for d in "$HOME/.local/bin" "$HOME/.hermes/bin" "$HOME/.hermes/node/bin" \
           "$HOME/.openclaw/bin" "$HOME/.volta/bin" "$HOME/.nvm/current/bin"; do
    [[ -d "$d" ]] && PATH="$d:$PATH"
  done
  export PATH
  if ! command -v node >/dev/null 2>&1; then
    found="$(find "$HOME/.hermes" "$HOME/.local" -maxdepth 5 -type f -name node -perm -u+x -print -quit 2>/dev/null || true)"
    [[ -n "$found" ]] && PATH="$(dirname "$found"):$PATH" && export PATH
  fi
}

find_hermes(){
  local x
  for x in "$(command -v hermes 2>/dev/null || true)" "$HOME/.local/bin/hermes" \
           "$HOME/.hermes/bin/hermes" "$HOME/.hermes/hermes-agent/venv/bin/hermes"; do
    [[ -n "$x" && -x "$x" ]] && { printf '%s\n' "$x"; return 0; }
  done
  return 1
}

find_openclaw(){
  local x
  for x in "$(command -v openclaw 2>/dev/null || true)" "$HOME/.local/bin/openclaw" "$HOME/.openclaw/bin/openclaw"; do
    [[ -n "$x" && -x "$x" ]] && { printf '%s\n' "$x"; return 0; }
  done
  return 1
}

ensure_linger(){
  local linger
  linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)"
  if [[ "$linger" != "yes" ]]; then
    log "Enabling systemd user lingering so agents start at boot before GUI login..."
    sudo loginctl enable-linger "$USER"
  fi
  linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)"
  [[ "$linger" == "yes" ]] || die "Could not enable loginctl linger for $USER"
  ok "Boot persistence enabled: loginctl linger=yes"
}

ensure_hermes_gateway(){
  local unit="hermes-gateway.service"
  if systemctl --user cat "$unit" >/dev/null 2>&1; then
    ok "Hermes gateway service exists; installer skipped"
  else
    log "Hermes gateway service missing; installing only this component..."
    "$HERMES" gateway install --start-now --start-on-login >/dev/null || die "Hermes gateway install failed"
  fi

  systemctl --user enable "$unit" >/dev/null 2>&1 || true
  if ! systemctl --user is-active --quiet "$unit"; then
    log "Starting Hermes gateway service..."
    "$HERMES" gateway start >/dev/null || systemctl --user start "$unit" || die "Hermes gateway start failed"
  fi

  for _ in $(seq 1 20); do
    systemctl --user is-active --quiet "$unit" && break
    sleep 1
  done
  systemctl --user is-active --quiet "$unit" || die "Hermes gateway is not active"
  systemctl --user is-enabled --quiet "$unit" || die "Hermes gateway is not enabled for boot"
  ok "Hermes gateway enabled + running"
}

ensure_dashboard_dependencies(){
  local py="$HOME/.hermes/hermes-agent/venv/bin/python"
  local repo="$HOME/.hermes/hermes-agent"
  [[ -x "$py" ]] || { warn "Hermes venv Python not found; dashboard dependency check skipped"; return 0; }

  if "$py" - <<'PY' >/dev/null 2>&1
import fastapi, uvicorn, ptyprocess
PY
  then
    ok "Hermes dashboard dependencies already exist; install skipped"
    return 0
  fi

  [[ -d "$repo" ]] || die "Hermes repository not found at $repo"
  log "Hermes dashboard dependencies missing; installing ONLY web+pty extras..."
  if command -v uv >/dev/null 2>&1; then
    (cd "$repo" && uv pip install --python "$py" -e '.[web,pty]')
  elif [[ -x "$HOME/.hermes/uv" ]]; then
    (cd "$repo" && "$HOME/.hermes/uv" pip install --python "$py" -e '.[web,pty]')
  else
    "$py" -m pip install -e "${repo}[web,pty]"
  fi
  "$py" - <<'PY' >/dev/null
import fastapi, uvicorn, ptyprocess
PY
  ok "Hermes dashboard dependencies verified"
}

ensure_control_secrets(){
  mkdir -p "$CONTROL_DIR"; chmod 700 "$CONTROL_DIR"
  if [[ ! -s "$CONTROL_ENV" ]]; then
    local hpass hsecret otoken
    hpass="$(openssl rand -base64 24 | tr -d '\n')"
    hsecret="$(openssl rand -base64 32 | tr -d '\n')"
    otoken="$(openssl rand -hex 32)"
    cat >"$CONTROL_ENV" <<EOF2
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${hpass}
HERMES_DASHBOARD_BASIC_AUTH_SECRET=${hsecret}
OPENCLAW_CONTROL_TOKEN=${otoken}
EOF2
    chmod 600 "$CONTROL_ENV"
    ok "LAN control credentials generated automatically; secrets not printed"
  else
    ok "Existing LAN control credentials reused"
  fi
}

ensure_hermes_dashboard(){
  local bind="127.0.0.1"
  local envline=""
  if [[ "$LAN_CONTROL" == "1" ]]; then
    ensure_control_secrets
    bind="0.0.0.0"
    envline="EnvironmentFile=$CONTROL_ENV"
  fi

  mkdir -p "$HOME/.config/systemd/user"
  local unit="$HOME/.config/systemd/user/$HERMES_DASHBOARD_UNIT"
  local tmp="$(mktemp)"
  cat >"$tmp" <<EOF2
[Unit]
Description=auto_agent Hermes Web Dashboard
After=network-online.target hermes-gateway.service
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=$HOME
Environment=PATH=$PATH
${envline}
WorkingDirectory=$HOME
ExecStart=$HERMES dashboard --host $bind --port $HERMES_DASHBOARD_PORT --no-open
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF2

  if ! cmp -s "$tmp" "$unit" 2>/dev/null; then
    install -m 600 "$tmp" "$unit"
    systemctl --user daemon-reload
  fi
  rm -f "$tmp"

  systemctl --user enable --now "$HERMES_DASHBOARD_UNIT" >/dev/null
  for _ in $(seq 1 30); do
    curl -fsS --max-time 2 "http://127.0.0.1:${HERMES_DASHBOARD_PORT}/api/status" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS --max-time 3 "http://127.0.0.1:${HERMES_DASHBOARD_PORT}/api/status" >/dev/null \
    || { systemctl --user status "$HERMES_DASHBOARD_UNIT" --no-pager || true; die "Hermes dashboard is not reachable"; }
  ok "Hermes dashboard enabled + reachable on port $HERMES_DASHBOARD_PORT"
}

openclaw_status_json(){ "$OPENCLAW" gateway status --json 2>/dev/null || true; }
openclaw_field(){
  python3 - "$1" "$2" <<'PY'
import json,sys
try:
 d=json.loads(sys.argv[1]); svc=d.get('service') or {}; rt=svc.get('runtime') or {}
 vals={
  'installed': bool(svc.get('command') is not None or svc.get('loaded')),
  'running': rt.get('status') == 'running',
 }
 print('1' if vals.get(sys.argv[2], False) else '0')
except Exception:
 print('0')
PY
}

openclaw_startup_probe(){
  curl -fsS --connect-timeout 2 --max-time 3 \
    "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/startupz" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True and d.get("status")=="started"' \
    >/dev/null 2>&1
}

configure_openclaw_access(){
  if [[ "$LAN_CONTROL" == "1" ]]; then
    ensure_control_secrets
    # shellcheck disable=SC1090
    source "$CONTROL_ENV"
    "$OPENCLAW" config set gateway.bind lan >/dev/null
    "$OPENCLAW" config set gateway.auth.mode token >/dev/null
    "$OPENCLAW" config set gateway.auth.token "$OPENCLAW_CONTROL_TOKEN" >/dev/null
    ok "OpenClaw LAN control enabled with token authentication"
  else
    ok "LAN control not requested; preserving OpenClaw default/existing bind (normally loopback)"
  fi
}

ensure_openclaw_gateway(){
  local st installed running label enabled=0
  configure_openclaw_access
  st="$(openclaw_status_json)"
  installed="$(openclaw_field "$st" installed)"
  label="$(python3 - "$st" <<'PY'
import json,sys
try:
 d=json.loads(sys.argv[1]); print((d.get("service") or {}).get("label") or "")
except Exception:
 print("")
PY
)"
  if [[ -n "$label" ]] && systemctl --user is-enabled --quiet "$label" 2>/dev/null; then enabled=1; fi
  if [[ "$installed" != 1 || "$enabled" != 1 ]]; then
    log "OpenClaw gateway service missing/disabled; reconciling only the service definition..."
    "$OPENCLAW" gateway install --force >/dev/null || die "OpenClaw gateway install failed"
  else
    ok "OpenClaw gateway service exists + enabled; installer skipped"
  fi

  st="$(openclaw_status_json)"; running="$(openclaw_field "$st" running)"
  if [[ "$running" != 1 ]]; then
    "$OPENCLAW" gateway start >/dev/null || die "OpenClaw gateway start failed"
  fi

  for _ in $(seq 1 30); do
    st="$(openclaw_status_json)"; running="$(openclaw_field "$st" running)"
    if [[ "$running" == 1 ]] && openclaw_startup_probe; then
      ok "OpenClaw gateway enabled + running + /startupz=started"
      return 0
    fi
    sleep 1
  done
  "$OPENCLAW" gateway status || true
  curl -sS --max-time 3 "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/startupz" || true
  die "OpenClaw gateway failed service/startup HTTP readiness"
}

install_management_cli(){
  local out="$HOME/.local/bin/auto-agent"
  mkdir -p "$HOME/.local/bin"
  cat >"$out" <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH="$HOME/.local/bin:$HOME/.hermes/bin:$HOME/.hermes/node/bin:$HOME/.openclaw/bin:$PATH"
export PATH
HERMES="$(command -v hermes || true)"
OPENCLAW="$(command -v openclaw || true)"
HPORT="${HERMES_DASHBOARD_PORT:-9119}"
OPORT="${OPENCLAW_GATEWAY_PORT:-18789}"

case "${1:-status}" in
  status)
    echo "=== Hermes Gateway ==="
    "$HERMES" gateway status 2>/dev/null || true
    echo
    echo "=== Hermes Dashboard ==="
    systemctl --user --no-pager status auto-agent-hermes-dashboard.service || true
    echo
    echo "=== OpenClaw Gateway ==="
    systemctl --user is-active openclaw-gateway.service 2>/dev/null || true
    curl -fsS --max-time 3 "http://127.0.0.1:${OPORT}/startupz" 2>/dev/null || true
    echo
    echo "Hermes UI : http://127.0.0.1:${HPORT}"
    echo "OpenClaw  : run 'auto-agent openclaw-dashboard'"
    ;;
  start)
    "$HERMES" gateway start || true
    systemctl --user start auto-agent-hermes-dashboard.service
    "$OPENCLAW" gateway start || true
    ;;
  stop)
    "$OPENCLAW" gateway stop || true
    systemctl --user stop auto-agent-hermes-dashboard.service || true
    "$HERMES" gateway stop || true
    ;;
  restart)
    "$HERMES" gateway restart || true
    systemctl --user restart auto-agent-hermes-dashboard.service
    "$OPENCLAW" gateway restart --safe 2>/dev/null || "$OPENCLAW" gateway restart || true
    ;;
  hermes)
    shift; exec "$HERMES" "$@"
    ;;
  hermes-dashboard)
    url="http://127.0.0.1:${HPORT}"
    echo "$url"
    command -v xdg-open >/dev/null 2>&1 && xdg-open "$url" >/dev/null 2>&1 || true
    ;;
  openclaw-dashboard)
    shift; exec "$OPENCLAW" dashboard "$@"
    ;;
  logs)
    journalctl --user -u hermes-gateway.service -u auto-agent-hermes-dashboard.service -u openclaw-gateway.service -n 250 --no-pager || true
    ;;
  credentials)
    f="$HOME/.config/auto_agent/control.env"
    if [[ -r "$f" ]]; then
      cat "$f"
    else
      echo "LAN control credentials do not exist because LAN_CONTROL is disabled."
    fi
    ;;
  *)
    echo "Usage: auto-agent {status|start|stop|restart|hermes|hermes-dashboard|openclaw-dashboard|logs|credentials}" >&2
    exit 2
    ;;
esac
EOF2
  chmod 700 "$out"
  ok "Management CLI installed: $out"
}

configure_firewall_if_lan(){
  [[ "$LAN_CONTROL" == "1" ]] || return 0
  if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
    local iface cidr ip
    iface="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
    ip="$(ip -o -4 addr show dev "$iface" scope global | awk 'NR==1{print $4}')"
    cidr="$(python3 - "$ip" <<'PY'
import ipaddress,sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"
    sudo ufw allow from "$cidr" to any port "$HERMES_DASHBOARD_PORT" proto tcp >/dev/null
    sudo ufw allow from "$cidr" to any port "$OPENCLAW_GATEWAY_PORT" proto tcp >/dev/null
    ok "UFW LAN-only control rules configured for $cidr"
  else
    warn "LAN_CONTROL=1 but UFW is inactive; app authentication is enabled, but no host firewall rule was added"
  fi
}

prepare_path
HERMES="$(find_hermes)" || die "Hermes executable not found"
OPENCLAW="$(find_openclaw)" || die "OpenClaw executable not found"
command -v node >/dev/null 2>&1 || die "Node runtime not found for OpenClaw"
command -v openssl >/dev/null 2>&1 || { sudo apt-get update; sudo apt-get install -y openssl; }

log "Configuring boot-time services and control surfaces..."
ensure_linger
ensure_hermes_gateway
ensure_dashboard_dependencies
ensure_hermes_dashboard
ensure_openclaw_gateway
configure_firewall_if_lan
install_management_cli

printf '\n============================================================\n'
printf 'AUTO_AGENT BOOT + CONTROL READY\n'
printf 'Boot persistence : loginctl linger=yes\n'
printf 'Hermes Gateway   : enabled + running\n'
printf 'Hermes Dashboard : http://127.0.0.1:%s\n' "$HERMES_DASHBOARD_PORT"
printf 'OpenClaw Gateway : enabled + running + /startupz=started\n'
printf 'Control command  : auto-agent status\n'
printf 'LAN control      : %s\n' "$([[ "$LAN_CONTROL" == 1 ]] && echo enabled-authenticated || echo disabled-loopback-only)"
printf '============================================================\n'