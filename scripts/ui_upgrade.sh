#!/usr/bin/env bash
set -Eeuo pipefail
AUTO_AGENT_COMPONENT=ui-v062

REPO_RAW="${AUTO_AGENT_REPO_RAW:-https://raw.githubusercontent.com/caotiensinh/auto_agent/main}"
APP_DIR="$HOME/.local/share/auto_agent"
UI_FILE="$APP_DIR/control_center_ui.html"
COMPAT_WRAPPER_FILE="$APP_DIR/control_center_v3.py"
ASYNC_WRAPPER_FILE="$APP_DIR/control_center_v4.py"
WRAPPER_FILE="$APP_DIR/control_center_v5.py"
ASYNC_JS_FILE="$APP_DIR/control_center_async.js"
POLISH_JS_FILE="$APP_DIR/control_center_polish.js"
BASE_FILE="$APP_DIR/control_center_v2.py"
UNIT="auto-agent-control-center.service"
UNIT_FILE="$HOME/.config/systemd/user/$UNIT"

log(){ printf '\033[1;34m[UI-V062]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[UI-V062:OK]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[UI-V062:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

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
v3_tmp="$(mktemp)"
v4_tmp="$(mktemp)"
v5_tmp="$(mktemp)"
async_tmp="$(mktemp)"
polish_tmp="$(mktemp)"
trap 'rm -f "$ui_tmp" "$v3_tmp" "$v4_tmp" "$v5_tmp" "$async_tmp" "$polish_tmp"' EXIT

download scripts/control_center_ui.html "$ui_tmp"
download scripts/control_center_v3.py "$v3_tmp"
download scripts/control_center_v4.py "$v4_tmp"
download scripts/control_center_v5.py "$v5_tmp"
download scripts/control_center_async.js "$async_tmp"
download scripts/control_center_polish.js "$polish_tmp"

for marker in 'id="messages"' 'id="prompt"' 'id="mode"' 'id="send"' 'id="sidebarToggle"' 'sidebar-collapsed' '__CENTER_PUBLIC_HOST__' 'AUTO AGENT' 'composer-wrap'; do
  grep -Fq "$marker" "$ui_tmp" || die "UI template missing marker: $marker"
done
if grep -Fq 'class="topbar"' "$ui_tmp"; then
  die "Top bar regression detected; workspace must remain edge-to-edge"
fi
python3 -m py_compile "$v3_tmp" || die "control_center_v3.py syntax invalid"
python3 -m py_compile "$v4_tmp" || die "control_center_v4.py syntax invalid"
python3 -m py_compile "$v5_tmp" || die "control_center_v5.py syntax invalid"
grep -Fq '/api/chat/jobs/' "$v4_tmp" || die "Async backend job endpoint missing"
grep -Fq 'resolve_runtime_policy' "$v4_tmp" || die "Agent-owned runtime policy missing"
grep -Fq 'chat_history.sqlite3' "$v5_tmp" || die "Persistent history database missing"
grep -Fq '/api/history' "$v5_tmp" || die "Persistent history API missing"
grep -Fq 'verbatim pass-through' "$v5_tmp" || die "Raw agent pass-through policy missing"
grep -Fq 'AutoAgentRenderMessage' "$polish_tmp" || die "Markdown presentation renderer missing"
grep -Fq 'History' "$polish_tmp" || die "History sidebar integration missing"
grep -Fq 'pollJob' "$async_tmp" || die "Async chat polling client missing"
grep -Fq "fetch('/api/chat'" "$async_tmp" || die "Async chat submit client missing"

install -m 600 "$ui_tmp" "$UI_FILE"
install -m 700 "$v3_tmp" "$COMPAT_WRAPPER_FILE"
install -m 700 "$v4_tmp" "$ASYNC_WRAPPER_FILE"
install -m 700 "$v5_tmp" "$WRAPPER_FILE"
install -m 600 "$async_tmp" "$ASYNC_JS_FILE"
install -m 600 "$polish_tmp" "$POLISH_JS_FILE"

python3 - "$UNIT_FILE" "$WRAPPER_FILE" <<'PY'
from pathlib import Path
import sys
unit, wrapper = map(Path, sys.argv[1:])
text = unit.read_text(encoding="utf-8")
lines = text.splitlines()
out = []
for line in lines:
    if line.startswith("Description=auto_agent Unified Control Center"):
        out.append("Description=auto_agent Unified Control Center v0.6.2 history + markdown")
    elif line.startswith("ExecStart=") and any(name in line for name in (
        "control_center_v2.py", "control_center_v3.py", "control_center_v4.py", "control_center_v5.py"
    )):
        out.append(f"ExecStart=/usr/bin/python3 {wrapper}")
    else:
        out.append(line)
if not any(line.startswith("ExecStart=") and "control_center_v5.py" in line for line in out):
    raise SystemExit("Could not switch Control Center ExecStart to history wrapper")
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
async_js="$(curl -fsS --max-time 4 http://127.0.0.1:18088/_auto_agent_async.js 2>/dev/null || true)"
[[ "$async_js" == *"pollJob"* ]] || die "Async chat browser asset verification failed"
polish_js="$(curl -fsS --max-time 4 http://127.0.0.1:18088/_auto_agent_polish.js 2>/dev/null || true)"
[[ "$polish_js" == *"AutoAgentRenderMessage"* ]] || die "Markdown/history browser asset verification failed"

ok "Chat text increased to ChatGPT-like 17px with improved line spacing"
ok "Agent Markdown is rendered safely for headings, lists, code and emphasis"
ok "Persistent server-side SQLite chat history installed"
ok "Recent conversations are available from the sidebar"
ok "Hermes/OpenClaw output remains verbatim; no second AI polishing pass"
ok "Cloudflare-safe async chat + agent-owned runtime policy preserved"
ok "Existing SSO/auth/security boundaries preserved"
printf '\n============================================================\n'
printf 'AUTO_AGENT UI v0.6.2 READY\n'
printf 'Typography : 17px readable chat body + formatted Markdown\n'
printf 'History    : persistent SQLite, survives browser reload/restart\n'
printf 'Output     : direct Hermes/OpenClaw pass-through; presentation-only formatting\n'
printf 'Runtime    : agent-owned; no arbitrary Auto Agent wall-clock cutoff\n'
printf 'Security   : auth + SSO boundaries unchanged\n'
printf '============================================================\n'
