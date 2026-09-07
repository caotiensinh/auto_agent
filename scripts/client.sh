#!/usr/bin/env bash
set -Eeuo pipefail
AUTO_AGENT_COMPONENT=client

CONTEXT_LENGTH="${CONTEXT_LENGTH:-65536}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
UPDATE_HERMES="${UPDATE_HERMES:-0}"
UPDATE_OPENCLAW="${UPDATE_OPENCLAW:-0}"
PORT="${GATEWAY_PORT:-11434}"

log(){ printf '\033[1;34m[CLIENT]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[CLIENT:OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CLIENT:WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[CLIENT:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run as normal Ubuntu user, not root"
source /etc/os-release; [[ "${ID:-}" == ubuntu ]] || die "Ubuntu required"

pkg(){ dpkg-query -W -f='${Status}' "$1" 2>/dev/null|grep -q '^install ok installed$'; }
install_missing(){
 local m=() p; for p in "$@"; do pkg "$p" || m+=("$p"); done
 ((${#m[@]})) || { ok "Client packages already exist; apt skipped"; return; }
 log "Missing packages: ${m[*]}"; sudo apt-get update; sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${m[@]}"
}
hermes_cmd(){ for x in "$(command -v hermes 2>/dev/null||true)" "$HOME/.local/bin/hermes" "$HOME/.hermes/bin/hermes" "$HOME/.hermes/hermes-agent/venv/bin/hermes"; do [[ -x "$x" ]]&&{ echo "$x";return;};done; return 1; }
claw_cmd(){ for x in "$(command -v openclaw 2>/dev/null||true)" "$HOME/.local/bin/openclaw" "$HOME/.openclaw/bin/openclaw"; do [[ -x "$x" ]]&&{ echo "$x";return;};done; return 1; }

preflight(){
 printf '\n============================================================\nCLIENT PRE-FLIGHT INVENTORY (NO CHANGES YET)\n'
 printf 'OS              : %s\nKernel          : %s\nHostname        : %s\n' "$PRETTY_NAME" "$(uname -r)" "$(hostname)"
 HERMES="$(hermes_cmd 2>/dev/null||true)"; OPENCLAW="$(claw_cmd 2>/dev/null||true)"
 printf 'Hermes          : %s\n' "${HERMES:-missing}"
 printf 'OpenClaw        : %s\n' "${OPENCLAW:-missing}"
 if command -v ollama >/dev/null; then printf 'Local Ollama    : installed; preserved and not used/replaced\n'; ollama list 2>/dev/null|sed 's/^/  /'||true; else printf 'Local Ollama    : not installed; not required\n'; fi
 [[ -f "$HOME/.config/local-ai/server.env" ]]&&printf 'Cached server   : present; will try first\n'||printf 'Cached server   : none\n'
 printf 'Install policy  : reuse existing agents; install ONLY missing components\n============================================================\n\n'
}

probe(){
 python3 - "$1" "${2:-$PORT}"<<'PY'
import http.client,json,sys
try:
 c=http.client.HTTPConnection(sys.argv[1],int(sys.argv[2]),timeout=1)
 c.request("GET","/auto-agent/discovery"); r=c.getresponse(); d=json.loads(r.read(8192))
 if r.status==200 and d.get("service")=="auto_agent" and d.get("role")=="server": print(json.dumps(d,separators=(",",":")))
 else: raise SystemExit(1)
except: raise SystemExit(1)
PY
}
use_json(){
 readarray -t V < <(python3 - "$1"<<'PY'
import json,sys
d=json.loads(sys.argv[1])
for k in ("ip","gateway_port","ssh_user","model","context","hostname"): print(d.get(k,""))
PY
)
 SERVER_IP="${V[0]}"; SERVER_PORT="${V[1]:-$PORT}"; SSH_USER="${V[2]:-$USER}"; DISC_MODEL="${V[3]}"; SERVER_HOST="${V[5]}"; [[ -n "$SERVER_IP" ]]
}
from_cache(){
 local f="$HOME/.config/local-ai/server.env" ip p d; [[ -f "$f" ]]||return 1
 ip="$(grep '^SERVER_IP=' "$f"|head -1|cut -d= -f2-)"; p="$(grep '^GATEWAY_PORT=' "$f"|head -1|cut -d= -f2-)"; [[ -n "$ip" ]]||return 1; [[ "$p" =~ ^[0-9]+$ ]]||p="$PORT"
 d="$(probe "$ip" "$p" 2>/dev/null||true)"; [[ -n "$d" ]]||return 1; use_json "$d"
}
from_explicit(){
 local ip="${SERVER_IP_OVERRIDE:-${SERVER_IP:-}}" d; [[ -n "$ip" ]]||return 1
 d="$(probe "$ip" "$PORT" 2>/dev/null||true)"; [[ -n "$d" ]]||return 1; use_json "$d"
}
from_mdns(){
 local b l ip p d txt
 b="$(timeout 10 avahi-browse -rtp _local-ai._tcp 2>/dev/null||true)"
 l="$(awk -F';' '$1=="="&&$3=="IPv4"{print;exit}'<<<"$b")"; [[ -n "$l" ]]||return 1
 IFS=';' read -r _ _ _ _ _ _ SERVER_HOST ip p txt<<<"$l"; [[ -n "$ip" ]]||return 1
 d="$(probe "$ip" "$p" 2>/dev/null||true)"
 if [[ -n "$d" ]]; then use_json "$d"; return; fi
 SERVER_IP="$ip"; SERVER_PORT="$p"; SSH_USER="$(sed -nE 's/.*"ssh_user=([^"]+)".*/\1/p'<<<"$txt"|head -1)"; SSH_USER="${SSH_USER:-$USER}"; DISC_MODEL="$(sed -nE 's/.*"model=([^"]+)".*/\1/p'<<<"$txt"|head -1)"
}
scan_new(){
 local iface cidr j
 iface="$(ip -4 route show default|awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"; cidr="$(ip -o -4 addr show dev "$iface" scope global|awk 'NR==1{print $4}')"
 j="$(python3 - "$cidr" "$PORT"<<'PY'
import concurrent.futures,http.client,ipaddress,json,sys
me=ipaddress.ip_interface(sys.argv[1]); port=int(sys.argv[2]); net=me.network if me.network.num_addresses<=4096 else ipaddress.ip_network(f"{me.ip}/24",strict=False)
def p(x):
 x=str(x)
 if x==str(me.ip): return
 try:
  c=http.client.HTTPConnection(x,port,timeout=.35); c.request("GET","/auto-agent/discovery"); r=c.getresponse(); d=json.loads(r.read(8192))
  if r.status==200 and d.get("service")=="auto_agent": return json.dumps(d,separators=(",",":"))
 except: pass
with concurrent.futures.ThreadPoolExecutor(max_workers=96) as e:
 for r in e.map(p,list(net.hosts())):
  if r: print(r); raise SystemExit(0)
raise SystemExit(1)
PY
)"||return 1
 use_json "$j"
}
scan_legacy(){
 local iface cidr ip
 iface="$(ip -4 route show default|awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"; cidr="$(ip -o -4 addr show dev "$iface" scope global|awk 'NR==1{print $4}')"
 ip="$(python3 - "$cidr" "$PORT"<<'PY'
import concurrent.futures,http.client,ipaddress,sys
me=ipaddress.ip_interface(sys.argv[1]); port=int(sys.argv[2]); net=me.network if me.network.num_addresses<=4096 else ipaddress.ip_network(f"{me.ip}/24",strict=False)
def p(x):
 x=str(x)
 if x==str(me.ip): return
 try:
  c=http.client.HTTPConnection(x,port,timeout=.3); c.request("GET","/api/tags"); r=c.getresponse(); r.read(128)
  if r.status==401:return x
 except: pass
with concurrent.futures.ThreadPoolExecutor(max_workers=96) as e:
 for r in e.map(p,list(net.hosts())):
  if r: print(r); raise SystemExit(0)
raise SystemExit(1)
PY
)"||return 1
 SERVER_IP="$ip"; SERVER_PORT="$PORT"; SSH_USER="$USER"; SERVER_HOST=""; DISC_MODEL=""
}
discover(){
 from_explicit&&{ METHOD=explicit;return; }
 from_cache&&{ METHOD=cache;return; }
 from_mdns&&{ METHOD=mdns;return; }
 scan_new&&{ METHOD=http-scan;return; }
 scan_legacy&&{ METHOD=legacy-401-scan;return; }
 return 1
}

ssh_meta(){
 mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
 if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then KEY="$HOME/.ssh/id_ed25519.pub"; elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then KEY="$HOME/.ssh/id_rsa.pub"; else ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519"; KEY="$HOME/.ssh/id_ed25519.pub"; fi
 SSH_TARGET="${SSH_USER}@${SERVER_IP}"; OPT=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
 if ssh "${OPT[@]}" -o BatchMode=yes "$SSH_TARGET" true >/dev/null 2>&1; then ok "SSH trust already exists"; else warn "One GPU-server password entry may be required"; ssh-copy-id "${OPT[@]}" -i "$KEY" "$SSH_TARGET"||die "SSH pairing failed"; fi
 E="$(ssh "${OPT[@]}" "$SSH_TARGET" 'cat ~/.config/local-ai/client.env')"||die "Cannot read server metadata"
 TOKEN="$(grep '^API_TOKEN='<<<"$E"|head -1|cut -d= -f2-)"; MODEL="$(grep '^MODEL='<<<"$E"|head -1|cut -d= -f2-)"; C="$(grep '^CONTEXT_LENGTH='<<<"$E"|head -1|cut -d= -f2-)"; P="$(grep '^GATEWAY_PORT='<<<"$E"|head -1|cut -d= -f2-)"
 [[ "$TOKEN" =~ ^[A-Fa-f0-9]{64}$ ]]||die "Invalid server token"; [[ -n "$MODEL" ]]||MODEL="${DISC_MODEL:-qwen3.5:9b}"; [[ "$C" =~ ^[0-9]+$ ]]&&CONTEXT_LENGTH="$C"; [[ "$P" =~ ^[0-9]+$ ]]&&SERVER_PORT="$P"
 OLLAMA_URL="http://${SERVER_IP}:${SERVER_PORT}"; OPENAI_URL="$OLLAMA_URL/v1"
 mkdir -p "$HOME/.config/local-ai"; chmod 700 "$HOME/.config/local-ai"
 cat >"$HOME/.config/local-ai/server.env"<<EOF
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

apis(){
 curl -fsS -H "Authorization: Bearer $TOKEN" "$OLLAMA_URL/api/tags" >/dev/null||die "Ollama API failed"
 curl -fsS -H "Authorization: Bearer $TOKEN" "$OPENAI_URL/models" >/dev/null||die "OpenAI-compatible API failed"
 ok "Remote GPU APIs verified"
}

ensure_hermes(){
 HERMES="$(hermes_cmd 2>/dev/null||true)"
 if [[ -n "$HERMES" && "$UPDATE_HERMES" != 1 ]]; then ok "Hermes exists; installer skipped"; else
  log "Installing/updating Hermes only because it is missing or explicitly requested"
  t="$(mktemp)"; curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o "$t"; bash "$t" --non-interactive --skip-setup; rm -f "$t"; export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"; HERMES="$(hermes_cmd)"||die "Hermes executable missing"
 fi
 mkdir -p "$HERMES_HOME"; chmod 700 "$HERMES_HOME"
 python3 - "$HERMES_HOME/config.yaml" "$MODEL" "$OPENAI_URL" "$TOKEN" "$CONTEXT_LENGTH"<<'PY'
import pathlib,sys,yaml
p=pathlib.Path(sys.argv[1]); old=p.read_text() if p.exists() else ""; d=yaml.safe_load(old) if old.strip() else {}
if not isinstance(d,dict): raise SystemExit("Bad Hermes config")
m=d.setdefault("model",{}); m.update(default=sys.argv[2],provider="custom",base_url=sys.argv[3],api_key=sys.argv[4],context_length=int(sys.argv[5]))
new=yaml.safe_dump(d,sort_keys=False,allow_unicode=True)
if new!=old:
 if p.exists(): p.with_name(p.name+".bak").write_text(old)
 p.write_text(new)
PY
 chmod 600 "$HERMES_HOME/config.yaml"
}

ensure_claw(){
 OPENCLAW="$(claw_cmd 2>/dev/null||true)"
 if [[ -n "$OPENCLAW" && "$UPDATE_OPENCLAW" != 1 ]]; then ok "OpenClaw exists; installer skipped"; else
  log "Installing/updating OpenClaw only because it is missing or explicitly requested"
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh|bash -s -- --no-prompt --no-onboard --verify
  export PATH="$HOME/.local/bin:$HOME/.openclaw/bin:$PATH"; OPENCLAW="$(claw_cmd)"||die "OpenClaw executable missing"
 fi
 [[ -f "$HOME/.openclaw/openclaw.json" ]]||"$OPENCLAW" setup --baseline >/dev/null
 "$OPENCLAW" config set models.providers.ollama.baseUrl "$OLLAMA_URL" >/dev/null
 "$OPENCLAW" config set models.providers.ollama.api ollama >/dev/null
 "$OPENCLAW" config set models.providers.ollama.apiKey "$TOKEN" >/dev/null
 "$OPENCLAW" models set "ollama/$MODEL" >/dev/null
 "$OPENCLAW" config set tools.profile messaging >/dev/null
 "$OPENCLAW" config set agents.defaults.heartbeat.every 0m >/dev/null
 "$OPENCLAW" config set gateway.mode local >/dev/null
 if "$OPENCLAW" gateway status >/dev/null 2>&1; then "$OPENCLAW" gateway restart >/dev/null||true; else "$OPENCLAW" gateway install --force >/dev/null; "$OPENCLAW" gateway restart >/dev/null||true; fi
 "$OPENCLAW" models list --provider ollama >/dev/null||die "OpenClaw provider verification failed"
}

preflight
install_missing ca-certificates curl python3 python3-yaml avahi-daemon avahi-utils openssh-client iproute2
sudo systemctl enable --now avahi-daemon >/dev/null
discover||die "GPU server not found by cache, mDNS, HTTP subnet scan, or legacy :11434 scan"
ok "GPU server discovered via $METHOD: $SERVER_IP:$SERVER_PORT"
ssh_meta
apis
ensure_hermes
ensure_claw

printf '\n============================================================\nAUTO_AGENT LAPTOP READY\n'
printf 'Discovery : %s\nGPU server: %s:%s\nModel     : %s\nHermes    : %s\nOpenClaw  : %s\n' "$METHOD" "$SERVER_IP" "$SERVER_PORT" "$MODEL" "$HERMES" "$OPENCLAW"
printf '============================================================\n'
