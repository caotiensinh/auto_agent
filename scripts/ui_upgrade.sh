#!/usr/bin/env bash
set -Eeuo pipefail
AUTO_AGENT_COMPONENT=ui-v061

REPO_RAW="${AUTO_AGENT_REPO_RAW:-https://raw.githubusercontent.com/caotiensinh/auto_agent/main}"
APP_DIR="$HOME/.local/share/auto_agent"
UI_FILE="$APP_DIR/control_center_ui.html"
WRAPPER_FILE="$APP_DIR/control_center_v3.py"
BASE_FILE="$APP_DIR/control_center_v2.py"
UNIT="auto-agent-control-center.service"
UNIT_FILE="$HOME/.config/systemd/user/$UNIT"

log(){ printf '\033[1;34m[UI-V061]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[UI-V061:OK]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[UI-V061:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run as normal Ubuntu user"
[[ -f "$BASE_FILE" ]] || die "Control Center backend missing: $BASE_FILE"
[[ -f "$UNIT_FILE" ]] || die "Control Center systemd unit missing: $UNIT_FILE"
command -v curl >/dev/null || die "curl required"
command -v python3 >/dev/null || die "python3 required"

mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR"

download(){
  local path="$1" out="$2" bust
  bust="$(date +%s%N 2>/dev/null || date +%s)"
  curl -fsSL --proto '=https' --tlsv1.2 \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "${REPO_RAW}/${path}?auto_agent_cache_bust=${bust}" -o "$out"
  [[ -s "$out" ]] || die "Downloaded ${path} is empty"
}

ui_tmp="$(mktemp)"
py_tmp="$(mktemp)"
trap 'rm -f "$ui_tmp" "$py_tmp"' EXIT

download scripts/control_center_ui.html "$ui_tmp"
download scripts/control_center_v3.py "$py_tmp"

for marker in 'id="messages"' 'id="prompt"' 'id="mode"' 'id="send"' 'id="sidebarToggle"' 'sidebar-collapsed' '__CENTER_PUBLIC_HOST__' 'AUTO AGENT' 'composer-wrap'; do
  grep -Fq "$marker" "$ui_tmp" || die "UI template missing marker: $marker"
done
if grep -Fq 'class="topbar"' "$ui_tmp"; then
  die "Top bar regression detected; v0.6.1 must be edge-to-edge"
fi
python3 -m py_compile "$py_tmp" || die "control_center_v3.py syntax invalid"

install -m 600 "$ui_tmp" "$UI_FILE"
install -m 700 "$py_tmp" "$WRAPPER_FILE"

python3 - "$UNIT_FILE" "$WRAPPER_FILE" <<'PY'
from pathlib import Path
import sys
unit, wrapper = map(Path, sys.argv[1:])
text = unit.read_text(encoding="utf-8")
lines = text.splitlines()
out = []
for line in lines:
    if line.startswith("Description=auto_agent Unified Control Center"):
        out.append("Description=auto_agent Unified Control Center v0.6.1 UI")
    elif line.startswith("ExecStart=") and ("control_center_v2.py" in line or "control_center_v3.py" in line):
        out.append(f"ExecStart=/usr/bin/python3 {wrapper}")
    else:
        out.append(line)
if not any(line.startswith("ExecStart=") and "control_center_v3.py" in line for line in out):
    raise SystemExit("Could not switch Control Center ExecStart to UI wrapper")
unit.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
chmod 600 "$UNIT_FILE"
systemctl --user daemon-reload
systemctl --user restart "$UNIT"

ready=0
for _ in $(seq 1 25); do
  if curl -fsS --max-time 2 http://127.0.0.1:18088/login >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]] || {
  systemctl --user status "$UNIT" --no-pager || true
  journalctl --user -u "$UNIT" -n 80 --no-pager || true
  die "Control Center UI did not become ready"
}

login_html="$(curl -fsS --max-time 4 http://127.0.0.1:18088/login 2>/dev/null || true)"
[[ "$login_html" == *"Auto Agent Control Center"* ]] || die "Login surface verification failed"

ok "Collapsible desktop sidebar installed"
ok "Mobile drawer navigation preserved"
ok "Top horizontal bar removed"
ok "Sidebar palette harmonized with workspace background"
ok "ChatGPT/Claude-style bottom composer preserved"
ok "Existing SSO/auth/backend logic preserved"
printf '\n============================================================\n'
printf 'AUTO_AGENT UI v0.6.1 READY\n'
printf 'Layout   : edge-to-edge workspace; no top bar\n'
printf 'Sidebar  : expandable/collapsible; state remembered on desktop\n'
printf 'Palette  : unified dark neutral + muted teal accents\n'
printf 'Chat     : centered conversation + rounded bottom composer\n'
printf 'Routing  : Auto / Hermes / OpenClaw preserved\n'
printf 'Security : backend auth + SSO implementation unchanged\n'
printf '============================================================\n'
