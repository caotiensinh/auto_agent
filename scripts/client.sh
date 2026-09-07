#!/usr/bin/env bash
set -Eeuo pipefail
AUTO_AGENT_COMPONENT=client

CONTEXT_LENGTH="${CONTEXT_LENGTH:-65536}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
UPDATE_HERMES="${UPDATE_HERMES:-0}"
UPDATE_OPENCLAW="${UPDATE_OPENCLAW:-0}"
PORT="${GATEWAY_PORT:-11434}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

log(){ printf '\033[1;34m[CLIENT]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[CLIENT:OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CLIENT:WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[CLIENT:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run as normal Ubuntu user, not root"
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "Ubuntu required"
command -v sudo >/dev/null 2>&1 || die "sudo is required"

pkg(){ dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

install_missing(){
  local missing=() p
  for p in "$@"; do pkg "$p" || missing+=("$p"); done
  ((${#missing[@]})) || { ok "Client packages already exist; apt skipped"; return; }
  log "Missing packages: ${missing[*]}"
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

hermes_cmd(){
  local x
  for x in "$(command -v hermes 2>/dev/null || true)" \
           "$HOME/.local/bin/hermes" \
           "$HOME/.hermes/bin/hermes" \
           "$HOME/.hermes/hermes-agent/venv/bin/hermes"; do
    [[ -n "$x" && -x "$x" ]] && { printf '%s\n' "$x"; return 0; }
  done
  return 1
}

claw_cmd(){
  local x
  for x in "$(command -v openclaw 2>/dev/null || true)" \
           "$HOME/.local/bin/openclaw" \
           "$HOME/.openclaw/bin/openclaw"; do
    [[ -n "$x" && -x "$x" ]] && { printf '%s\n' "$x"; return 0; }
  done
  return 1
}

preflight(){
  HERMES="$(hermes_cmd 2>/dev/null || true)"
  OPENCLAW="$(claw_cmd 2>/dev/null || true)"
  printf '\n============================================================\n'
  printf 'CLIENT PRE-FLIGHT INVENTORY (NO CHANGES YET)\n'
  printf 'OS              : %s\n' "$PRETTY_NAME"
  printf 'Kernel          : %s\n' "$(uname -r)"
  printf 'Hostname        : %s\n' "$(hostname)"
  printf 'Hermes          : %s\n' "${HERMES:-missing}"
  printf 'OpenClaw        : %s\n' "${OPENCLAW:-missing}"
  if command -v ollama >/dev/null 2>&1; then
    printf 'Local Ollama    : installed; preserved and not used/replaced\n'
    ollama list 2>/dev/null | sed 's/^/  /' || true
  else
    printf 'Local Ollama    : not installed; not required\n'
  fi
  if [[ -f "$HOME/.config/local-ai/server.env" ]]; then
    printf 'Cached server   : present; will try first\n'
  else
    printf 'Cached server   : none\n'
  fi
  printf 'Install policy  : reuse existing agents; install ONLY missing components\n'
  printf 'READY policy    : remote inference + Hermes config + OpenClaw /startupz must PASS\n'
  printf '============================================================\n\n'
}

probe(){
  python3 - "$1" "${2:-$PORT}" <<'PY'
import http.client, json, sys
try:
    c = http.client.HTTPConnection(sys.argv[1], int(sys.argv[2]), timeout=1)
    c.request("GET", "/auto-agent/discovery")
    r = c.getresponse()
    d = json.loads(r.read(8192))
    if r.status == 200 and d.get("service") == "auto_agent" and d.get("role") == "server":
        print(json.dumps(d, separators=(",", ":")))
    else:
        raise SystemExit(1)
except Exception:
    raise SystemExit(1)
PY
}

use_json(){
  readarray -t V < <(python3 - "$1" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
for k in ("ip","gateway_port","ssh_user","model","context","hostname"):
    print(d.get(k, ""))
PY
)
  SERVER_IP="${V[0]}"
  SERVER_PORT="${V[1]:-$PORT}"
  SSH_USER="${V[2]:-$USER}"
  DISC_MODEL="${V[3]}"
  SERVER_HOST="${V[5]}"
  [[ -n "$SERVER_IP" ]]
}

from_cache(){
  local f="$HOME/.config/local-ai/server.env" ip p d
  [[ -f "$f" ]] || return 1
  ip="$(grep '^SERVER_IP=' "$f" | head -1 | cut -d= -f2-)"
  p="$(grep '^GATEWAY_PORT=' "$f" | head -1 | cut -d= -f2-)"
  [[ -n "$ip" ]] || return 1
  [[ "$p" =~ ^[0-9]+$ ]] || p="$PORT"
  d="$(probe "$ip" "$p" 2>/dev/null || true)"
  [[ -n "$d" ]] || return 1
  use_json "$d"
}

from_explicit(){
  local ip="${SERVER_IP_OVERRIDE:-${SERVER_IP:-}}" d
  [[ -n "$ip" ]] || return 1
  d="$(probe "$ip" "$PORT" 2>/dev/null || true)"
  [[ -n "$d" ]] || return 1
  use_json "$d"
}

from_mdns(){
  local b l ip p d txt
  b="$(timeout 10 avahi-browse -rtp _local-ai._tcp 2>/dev/null || true)"
  l="$(awk -F';' '$1=="="&&$3=="IPv4"{print;exit}' <<<"$b")"
  [[ -n "$l" ]] || return 1
  IFS=';' read -r _ _ _ _ _ _ SERVER_HOST ip p txt <<<"$l"
  [[ -n "$ip" ]] || return 1
  d="$(probe "$ip" "$p" 2>/dev/null || true)"
  if [[ -n "$d" ]]; then use_json "$d"; return 0; fi
  SERVER_IP="$ip"
  SERVER_PORT="$p"
  SSH_USER="$(sed -nE 's/.*"ssh_user=([^"]+)".*/\1/p' <<<"$txt" | head -1)"
  SSH_USER="${SSH_USER:-$USER}"
  DISC_MODEL="$(sed -nE 's/.*"model=([^"]+)".*/\1/p' <<<"$txt" | head -1)"
}

scan_new(){
  local iface cidr j
  iface="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
  cidr="$(ip -o -4 addr show dev "$iface" scope global | awk 'NR==1{print $4}')"
  j="$(python3 - "$cidr" "$PORT" <<'PY'
import concurrent.futures, http.client, ipaddress, json, sys
me = ipaddress.ip_interface(sys.argv[1]); port = int(sys.argv[2])
net = me.network if me.network.num_addresses <= 4096 else ipaddress.ip_network(f"{me.ip}/24", strict=False)
def probe(ip):
    ip = str(ip)
    if ip == str(me.ip): return None
    try:
        c = http.client.HTTPConnection(ip, port, timeout=.35)
        c.request("GET", "/auto-agent/discovery")
        r = c.getresponse(); d = json.loads(r.read(8192))
        if r.status == 200 and d.get("service") == "auto_agent" and d.get("role") == "server":
            return json.dumps(d, separators=(",", ":"))
    except Exception:
        pass
with concurrent.futures.ThreadPoolExecutor(max_workers=96) as ex:
    for result in ex.map(probe, list(net.hosts())):
        if result:
            print(result)
            raise SystemExit(0)
raise SystemExit(1)
PY
)" || return 1
  use_json "$j"
}

scan_legacy(){
  local iface cidr ip
  iface="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
  cidr="$(ip -o -4 addr show dev "$iface" scope global | awk 'NR==1{print $4}')"
  ip="$(python3 - "$cidr" "$PORT" <<'PY'
import concurrent.futures, http.client, ipaddress, sys
me = ipaddress.ip_interface(sys.argv[1]); port = int(sys.argv[2])
net = me.network if me.network.num_addresses <= 4096 else ipaddress.ip_network(f"{me.ip}/24", strict=False)
def probe(ip):
    ip = str(ip)
    if ip == str(me.ip): return None
    try:
        c = http.client.HTTPConnection(ip, port, timeout=.3)
        c.request("GET", "/api/tags")
        r = c.getresponse(); r.read(128)
        if r.status == 401: return ip
    except Exception:
        pass
with concurrent.futures.ThreadPoolExecutor(max_workers=96) as ex:
    for result in ex.map(probe, list(net.hosts())):
        if result:
            print(result)
            raise SystemExit(0)
raise SystemExit(1)
PY
)" || return 1
  SERVER_IP="$ip"
  SERVER_PORT="$PORT"
  SSH_USER="$USER"
  SERVER_HOST=""
  DISC_MODEL=""
}

discover(){
  from_explicit && { METHOD=explicit; return 0; }
  from_cache && { METHOD=cache; return 0; }
  from_mdns && { METHOD=mdns; return 0; }
  scan_new && { METHOD=http-scan; return 0; }
  scan_legacy && { METHOD=legacy-401-scan; return 0; }
  return 1
}

ssh_meta(){
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
    KEY="$HOME/.ssh/id_ed25519.pub"
  elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
    KEY="$HOME/.ssh/id_rsa.pub"
  else
    ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519"
    KEY="$HOME/.ssh/id_ed25519.pub"
  fi

  SSH_TARGET="${SSH_USER}@${SERVER_IP}"
  OPT=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
  if ssh "${OPT[@]}" -o BatchMode=yes "$SSH_TARGET" true >/dev/null 2>&1; then
    ok "SSH trust already exists"
  else
    warn "One GPU-server password entry may be required"
    ssh-copy-id "${OPT[@]}" -i "$KEY" "$SSH_TARGET" || die "SSH pairing failed"
  fi

  E="$(ssh "${OPT[@]}" "$SSH_TARGET" 'cat ~/.config/local-ai/client.env')" || die "Cannot read server metadata"
  TOKEN="$(grep '^API_TOKEN=' <<<"$E" | head -1 | cut -d= -f2-)"
  MODEL="$(grep '^MODEL=' <<<"$E" | head -1 | cut -d= -f2-)"
  C="$(grep '^CONTEXT_LENGTH=' <<<"$E" | head -1 | cut -d= -f2-)"
  P="$(grep '^GATEWAY_PORT=' <<<"$E" | head -1 | cut -d= -f2-)"

  [[ "$TOKEN" =~ ^[A-Fa-f0-9]{64}$ ]] || die "Invalid server token"
  [[ -n "$MODEL" ]] || MODEL="${DISC_MODEL:-qwen3.5:9b}"
  [[ "$C" =~ ^[0-9]+$ ]] && CONTEXT_LENGTH="$C"
  [[ "$P" =~ ^[0-9]+$ ]] && SERVER_PORT="$P"

  OLLAMA_URL="http://${SERVER_IP}:${SERVER_PORT}"
  OPENAI_URL="$OLLAMA_URL/v1"

  mkdir -p "$HOME/.config/local-ai"; chmod 700 "$HOME/.config/local-ai"
  cat >"$HOME/.config/local-ai/server.env" <<EOF
SERVER_IP=${SERVER_IP}
GATEWAY_PORT=${SERVER_PORT}
SSH_USER=${SSH_USER}
MODEL=${MODEL}
CONTEXT_LENGTH=${CONTEXT_LENGTH}
API_TOKEN=${TOKEN}
OLLAMA_BASE_URL=${OLLAMA_URL}
OPENAI_BASE_URL=${OPENAI_URL}
EOF
  chmod 600 "$HOME/.config/local-ai/server.env"
}

verify_remote_inference(){
  log "Verifying authenticated GPU APIs and one real inference..."
  curl -fsS --connect-timeout 5 --max-time 20 \
    -H "Authorization: Bearer $TOKEN" "$OLLAMA_URL/api/tags" >/dev/null || die "Ollama API failed"
  curl -fsS --connect-timeout 5 --max-time 20 \
    -H "Authorization: Bearer $TOKEN" "$OPENAI_URL/models" >/dev/null || die "OpenAI-compatible API failed"
  timeout 300 curl -fsS "$OPENAI_URL/chat/completions" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$(python3 - "$MODEL" <<'PY'
import json,sys
print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":"Reply exactly CLIENT_GPU_OK"}],"max_tokens":32,"stream":False}))
PY
)" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("choices")' \
    || die "Remote chat-completions inference failed"
  ok "Remote GPU APIs + inference verified"
}

ensure_hermes(){
  HERMES="$(hermes_cmd 2>/dev/null || true)"
  if [[ -n "$HERMES" && "$UPDATE_HERMES" != 1 ]]; then
    ok "Hermes exists; installer skipped"
  else
    log "Installing/updating Hermes only because it is missing or explicitly requested"
    local t
    t="$(mktemp)"
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o "$t"
    bash "$t" --non-interactive --skip-setup
    rm -f "$t"
    export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"
    HERMES="$(hermes_cmd)" || die "Hermes executable missing"
  fi

  mkdir -p "$HERMES_HOME"; chmod 700 "$HERMES_HOME"
  python3 - "$HERMES_HOME/config.yaml" "$MODEL" "$OPENAI_URL" "$TOKEN" "$CONTEXT_LENGTH" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1])
old = p.read_text(encoding="utf-8") if p.exists() else ""
d = yaml.safe_load(old) if old.strip() else {}
if not isinstance(d, dict):
    raise SystemExit("Bad Hermes config")
m = d.setdefault("model", {})
if not isinstance(m, dict):
    raise SystemExit("Bad Hermes model config")
m.update(default=sys.argv[2], provider="custom", base_url=sys.argv[3],
         api_key=sys.argv[4], context_length=int(sys.argv[5]))
new = yaml.safe_dump(d, sort_keys=False, allow_unicode=True)
if new != old:
    if p.exists():
        p.with_name(p.name + ".bak").write_text(old, encoding="utf-8")
    p.write_text(new, encoding="utf-8")
PY
  chmod 600 "$HERMES_HOME/config.yaml"

  python3 - "$HERMES_HOME/config.yaml" "$MODEL" "$OPENAI_URL" "$CONTEXT_LENGTH" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
m = d["model"]
assert m["default"] == sys.argv[2]
assert m["provider"] == "custom"
assert m["base_url"] == sys.argv[3]
assert int(m["context_length"]) == int(sys.argv[4])
assert isinstance(m.get("api_key"), str) and len(m["api_key"]) >= 32
PY
  ok "Hermes configuration verified"
}

gateway_status_json(){
  "$OPENCLAW" gateway status --json 2>/dev/null || true
}

gateway_field(){
  python3 - "$1" "$2" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1]); key=sys.argv[2]
    svc=d.get("service") or {}; runtime=svc.get("runtime") or {}
    vals={
        "installed": bool(svc.get("command") is not None or svc.get("loaded")),
        "running": runtime.get("status")=="running",
    }
    print("1" if vals.get(key, False) else "0")
except Exception:
    print("0")
PY
}

openclaw_startup_probe(){
  curl -fsS --connect-timeout 2 --max-time 3 \
    "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/startupz" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True and d.get("status")=="started"' \
    >/dev/null 2>&1
}

ensure_openclaw_gateway(){
  local st installed running i
  st="$(gateway_status_json)"
  installed="$(gateway_field "$st" installed)"
  running="$(gateway_field "$st" running)"

  if [[ "$installed" != 1 ]]; then
    log "OpenClaw Gateway service missing; installing only this missing component..."
    "$OPENCLAW" gateway install --force >/dev/null || die "OpenClaw gateway install failed"
  fi

  st="$(gateway_status_json)"
  running="$(gateway_field "$st" running)"
  if [[ "$running" != 1 ]]; then
    log "OpenClaw Gateway service not running; starting it..."
    "$OPENCLAW" gateway start >/dev/null || die "OpenClaw gateway start failed"
  fi

  for i in $(seq 1 30); do
    st="$(gateway_status_json)"
    running="$(gateway_field "$st" running)"
    if [[ "$running" == 1 ]] && openclaw_startup_probe; then
      ok "OpenClaw Gateway service running; HTTP /startupz=started"
      return 0
    fi
    sleep 1
  done

  "$OPENCLAW" gateway status || true
  curl -sS --max-time 3 "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/startupz" || true
  die "OpenClaw gateway failed service/startup HTTP readiness"
}

ensure_claw(){
  OPENCLAW="$(claw_cmd 2>/dev/null || true)"
  if [[ -n "$OPENCLAW" && "$UPDATE_OPENCLAW" != 1 ]]; then
    ok "OpenClaw exists; installer skipped"
  else
    log "Installing/updating OpenClaw only because it is missing or explicitly requested"
    curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh \
      | bash -s -- --no-prompt --no-onboard --verify
    export PATH="$HOME/.local/bin:$HOME/.openclaw/bin:$PATH"
    OPENCLAW="$(claw_cmd)" || die "OpenClaw executable missing"
  fi

  [[ -f "$HOME/.openclaw/openclaw.json" ]] || "$OPENCLAW" setup --baseline >/dev/null

  "$OPENCLAW" config set models.providers.ollama.baseUrl "$OLLAMA_URL" >/dev/null
  "$OPENCLAW" config set models.providers.ollama.api ollama >/dev/null
  "$OPENCLAW" config set models.providers.ollama.apiKey "$TOKEN" >/dev/null
  "$OPENCLAW" models set "ollama/$MODEL" >/dev/null
  "$OPENCLAW" config set tools.profile messaging >/dev/null
  "$OPENCLAW" config set agents.defaults.heartbeat.every 0m >/dev/null
  "$OPENCLAW" config set gateway.mode local >/dev/null
  [[ -f "$HOME/.openclaw/openclaw.json" ]] && chmod 600 "$HOME/.openclaw/openclaw.json" || true

  "$OPENCLAW" models list --provider ollama >/dev/null || die "OpenClaw provider verification failed"
  ensure_openclaw_gateway
}

preflight
install_missing ca-certificates curl python3 python3-yaml avahi-daemon avahi-utils openssh-client iproute2
sudo systemctl enable --now avahi-daemon >/dev/null

discover || die "GPU server not found by cache, mDNS, HTTP subnet scan, or legacy :11434 scan"
ok "GPU server discovered via $METHOD: $SERVER_IP:$SERVER_PORT"

ssh_meta
verify_remote_inference
ensure_hermes
ensure_claw

printf '\n============================================================\n'
printf 'AUTO_AGENT LAPTOP READY\n'
printf 'Discovery : %s\n' "$METHOD"
printf 'GPU server: %s:%s\n' "$SERVER_IP" "$SERVER_PORT"
printf 'Model     : %s\n' "$MODEL"
printf 'Hermes    : %s\n' "$HERMES"
printf 'OpenClaw  : %s\n' "$OPENCLAW"
printf 'Gateway   : installed + running + /startupz=started\n'
printf '============================================================\n'