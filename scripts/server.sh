#!/usr/bin/env bash
set -Eeuo pipefail
AUTO_AGENT_COMPONENT=server

DEFAULT_MODEL="${DEFAULT_MODEL:-qwen3.5:9b}"
REQUESTED_MODEL="${MODEL:-}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-65536}"
MIN_AGENT_CONTEXT="${MIN_AGENT_CONTEXT:-65536}"
KEEP_ALIVE="${KEEP_ALIVE:-20m}"
GATEWAY_PORT="${GATEWAY_PORT:-11434}"
ROTATE_TOKEN="${ROTATE_TOKEN:-0}"
UPDATE_OLLAMA="${UPDATE_OLLAMA:-0}"
AUTO_INSTALL_NVIDIA_DRIVER="${AUTO_INSTALL_NVIDIA_DRIVER:-1}"
ALLOWED_NVIDIA_BRANCHES="${ALLOWED_NVIDIA_BRANCHES:-580 595}"

log(){ printf '\033[1;34m[SERVER]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[SERVER:OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[SERVER:WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[SERVER:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "Ubuntu is required"
if [[ $EUID -eq 0 ]]; then SUDO=""; INSTALL_USER="${SUDO_USER:-root}"; else SUDO=sudo; INSTALL_USER="${SUDO_USER:-$USER}"; fi
INSTALL_HOME="$(getent passwd "$INSTALL_USER"|cut -d: -f6)"
INSTALL_GROUP="$(id -gn "$INSTALL_USER")"

pkg(){ dpkg-query -W -f='${Status}' "$1" 2>/dev/null|grep -q '^install ok installed$'; }
install_missing(){
  local m=() p; for p in "$@"; do pkg "$p" || m+=("$p"); done
  ((${#m[@]})) || { ok "Required Ubuntu packages already exist; apt skipped"; return; }
  log "Missing packages: ${m[*]}"
  $SUDO apt-get update
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${m[@]}"
}
gpu_hw(){
  local f
  for f in /sys/bus/pci/devices/*/vendor; do [[ -r "$f" ]] && grep -qi '^0x10de$' "$f" && return 0; done
  return 1
}
gpu_ok(){ command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; }
nvpkg(){ dpkg-query -W -f='${Package}\t${Version}\n' 'nvidia-*' 2>/dev/null|grep -E '^(nvidia-driver|nvidia-dkms|libnvidia-compute)-' || true; }

preflight(){
  printf '\n============================================================\nSERVER PRE-FLIGHT INVENTORY (NO CHANGES YET)\n'
  printf 'OS              : %s\nKernel          : %s\nHostname        : %s\n' "$PRETTY_NAME" "$(uname -r)" "$(hostname)"
  if gpu_hw; then
    printf 'NVIDIA hardware : detected\n'
    if gpu_ok; then
      printf 'NVIDIA driver   : operational; REUSE\n'
      nvidia-smi --query-gpu=index,name,driver_version,memory.total,pci.bus_id --format=csv,noheader|sed 's/^/  GPU: /'
    else printf 'NVIDIA driver   : missing/broken\n'; fi
  else printf 'NVIDIA hardware : NOT detected\n'; fi
  printf 'NVIDIA packages :\n'; nvpkg|sed 's/^/  /'
  if command -v ollama >/dev/null; then
    printf 'Ollama          : installed; REUSE\nOllama version  : %s\nInstalled models:\n' "$(ollama --version 2>/dev/null|head -1)"
    ollama list 2>/dev/null|sed 's/^/  /' || printf '  inventory unavailable until service is healthy\n'
  else printf 'Ollama          : missing\nInstalled models: none\n'; fi
  printf 'Model policy    : reuse installed tool-capable model >= %s context; otherwise install only %s\n' "$MIN_AGENT_CONTEXT" "$DEFAULT_MODEL"
  printf 'Package policy  : install ONLY missing packages/components\n============================================================\n\n'
}

ensure_driver(){
  gpu_hw || die "No NVIDIA PCI hardware detected"
  if gpu_ok; then ok "NVIDIA driver healthy; no driver change"; return; fi
  [[ "$AUTO_INSTALL_NVIDIA_DRIVER" == 1 ]] || die "Driver missing/broken; auto-install disabled"
  install_missing pciutils ubuntu-drivers-common
  local rec branch a
  rec="$(ubuntu-drivers devices 2>/dev/null|grep recommended|grep -oE 'nvidia-driver-[0-9]+(-open)?'|head -1 || true)"
  [[ -n "$rec" ]] || die "Cannot determine recommended NVIDIA driver"
  branch="$(sed -nE 's/^nvidia-driver-([0-9]+)(-open)?$/\1/p'<<<"$rec")"
  for a in $ALLOWED_NVIDIA_BRANCHES; do [[ "$branch" == "$a" ]] && { log "Installing missing driver: $rec"; $SUDO apt-get install -y "$rec"; warn "Reboot required"; printf 'sudo reboot\nThen rerun the same installer.\n'; exit 20; }; done
  die "Recommended driver $rec is outside allowed branches: $ALLOWED_NVIDIA_BRANCHES"
}

network(){
  LAN_IF="$(ip -4 route show default|awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
  LAN_ADDR="$(ip -o -4 addr show dev "$LAN_IF" scope global|awk 'NR==1{print $4}')"
  SERVER_IP="${LAN_ADDR%/*}"
  LAN_CIDR="$(python3 - "$LAN_ADDR"<<'PY'
import ipaddress,sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"
}

ensure_ollama(){
  if command -v ollama >/dev/null && [[ "$UPDATE_OLLAMA" != 1 ]]; then
    ok "Ollama already installed; installer skipped"
  else
    [[ "$UPDATE_OLLAMA" == 1 ]] && log "Explicit Ollama update requested" || log "Ollama missing; installing it"
    curl -fsSL https://ollama.com/install.sh|sh
  fi
  command -v ollama >/dev/null || die "Ollama unavailable"
  if ! systemctl cat ollama.service >/dev/null 2>&1; then
    die "Ollama binary exists but systemd service is missing; run UPDATE_OLLAMA=1 once to install the service layer"
  fi
  $SUDO install -d -m0755 /etc/systemd/system/ollama.service.d
  local want cur
  want="[Service]
Environment=\"OLLAMA_HOST=127.0.0.1:11434\"
Environment=\"OLLAMA_CONTEXT_LENGTH=${CONTEXT_LENGTH}\"
Environment=\"OLLAMA_KEEP_ALIVE=${KEEP_ALIVE}\"
Environment=\"OLLAMA_NUM_PARALLEL=1\"
Environment=\"OLLAMA_MAX_LOADED_MODELS=1\""
  cur="$($SUDO cat /etc/systemd/system/ollama.service.d/10-auto-agent.conf 2>/dev/null || true)"
  if [[ "$cur" != "$want" ]]; then
    printf '%s\n' "$want"|$SUDO tee /etc/systemd/system/ollama.service.d/10-auto-agent.conf >/dev/null
    $SUDO systemctl daemon-reload; $SUDO systemctl enable --now ollama; $SUDO systemctl restart ollama
  else ok "Ollama integration config already matches"; $SUDO systemctl enable --now ollama >/dev/null; fi
  for _ in $(seq 1 60); do curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && return; sleep 1; done
  die "Ollama API did not become ready"
}

select_model(){
  local f; f="$(mktemp)"
  python3 - "$REQUESTED_MODEL" "$DEFAULT_MODEL" "$MIN_AGENT_CONTEXT" >"$f"<<'PY'
import json,sys,urllib.request
req,default,minctx=sys.argv[1],sys.argv[2],int(sys.argv[3])
def api(path,data=None):
    b=None if data is None else json.dumps(data).encode()
    r=urllib.request.Request("http://127.0.0.1:11434"+path,data=b,headers={"Content-Type":"application/json"},method="POST" if b else "GET")
    return json.load(urllib.request.urlopen(r,timeout=10))
rows=[]
for x in api("/api/tags").get("models",[]):
    n=x.get("name") or x.get("model")
    try:s=api("/api/show",{"model":n})
    except:s={}
    caps=s.get("capabilities") or []; mi=s.get("model_info") or {}
    ctx=max([v for k,v in mi.items() if isinstance(v,int) and str(k).endswith(".context_length")] or [0])
    rows.append((n,int(x.get("size") or 0),ctx,caps))
print("INVENTORY_BEGIN")
for n,size,ctx,caps in rows: print(f"{n}\t{size/1024**3:.1f} GiB\tcontext={ctx or 'unknown'}\tcaps={','.join(caps) or 'unknown'}")
if not rows: print("(none)")
print("INVENTORY_END")
names={r[0] for r in rows}
if req: sel=req; reason="explicit MODEL override"
else:
    e=[r for r in rows if "tools" in r[3] and r[2]>=minctx]
    def score(r):
        n=r[0].lower(); fam=50 if "qwen3.5" in n else 40 if "qwen3" in n else 30 if "qwen" in n else 25 if "glm" in n else 20 if "deepseek" in n else 10
        return fam,r[1],r[2]
    sel=sorted(e,key=score,reverse=True)[0][0] if e else default
    reason="reuse installed compatible model" if e else "no eligible installed model; use default fallback"
print("SELECTED="+sel); print("NEED_PULL="+("0" if sel in names else "1")); print("REASON="+reason)
PY
  log "Installed Ollama model inventory:"; sed -n '/INVENTORY_BEGIN/,/INVENTORY_END/p' "$f"|sed '1d;$d;s/^/  /'
  MODEL="$(grep '^SELECTED=' "$f"|cut -d= -f2-)"; NEED_PULL="$(grep '^NEED_PULL=' "$f"|cut -d= -f2-)"; MODEL_REASON="$(grep '^REASON=' "$f"|cut -d= -f2-)"; rm -f "$f"
  log "Selected model: $MODEL ($MODEL_REASON)"
  if [[ "$NEED_PULL" == 1 ]]; then log "Model missing; pulling ONLY $MODEL"; ollama pull "$MODEL"; else ok "Model already installed; download skipped"; fi
}

token(){
  $SUDO install -d -m0700 /etc/local-ai-gateway; TOKEN_FILE=/etc/local-ai-gateway/token
  if [[ "$ROTATE_TOKEN" == 1 || ! -s "$TOKEN_FILE" ]]; then TOKEN="$(openssl rand -hex 32)"; printf '%s\n' "$TOKEN"|$SUDO tee "$TOKEN_FILE" >/dev/null; $SUDO chmod 0600 "$TOKEN_FILE"; log "API token generated/rotated"
  else TOKEN="$($SUDO cat "$TOKEN_FILE")"; ok "Existing API token reused"; fi
}

gateway(){
  local json tmp
  json="$(python3 - "$SERVER_IP" "$INSTALL_USER" "$MODEL" "$CONTEXT_LENGTH" "$GATEWAY_PORT"<<'PY'
import json,socket,sys
print(json.dumps({"service":"auto_agent","role":"server","version":"0.2","hostname":socket.gethostname(),"ip":sys.argv[1],"ssh_user":sys.argv[2],"model":sys.argv[3],"context":int(sys.argv[4]),"gateway_port":int(sys.argv[5])},separators=(",",":")))
PY
)"
  tmp="$(mktemp)"
  cat >"$tmp"<<EOF
server {
 listen ${SERVER_IP}:${GATEWAY_PORT};
 server_name _;
 client_max_body_size 200m;
 location = /auto-agent/discovery { allow ${LAN_CIDR}; allow 127.0.0.1; deny all; default_type application/json; return 200 '${json}'; }
 location / {
  allow ${LAN_CIDR}; allow 127.0.0.1; deny all;
  if (\$http_authorization != "Bearer ${TOKEN}") { return 401; }
  proxy_pass http://127.0.0.1:11434;
  proxy_http_version 1.1; proxy_buffering off; proxy_request_buffering off;
  proxy_read_timeout 3600s; proxy_send_timeout 3600s;
  proxy_set_header Connection "";
 }
}
EOF
  if ! $SUDO cmp -s "$tmp" /etc/nginx/conf.d/local-ai-gateway.conf 2>/dev/null; then
    $SUDO install -m0600 "$tmp" /etc/nginx/conf.d/local-ai-gateway.conf; $SUDO nginx -t; $SUDO systemctl enable --now nginx; $SUDO systemctl reload nginx
  else ok "Nginx gateway already matches"; fi
  rm -f "$tmp"
}

discovery_ssh(){
  $SUDO systemctl enable --now ssh avahi-daemon >/dev/null
  local tmp; tmp="$(mktemp)"
  cat >"$tmp"<<EOF
<?xml version="1.0" standalone="no"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group><name replace-wildcards="yes">Local AI GPU on %h</name><service>
<type>_local-ai._tcp</type><port>${GATEWAY_PORT}</port>
<txt-record>ssh_user=${INSTALL_USER}</txt-record><txt-record>model=${MODEL}</txt-record>
<txt-record>context=${CONTEXT_LENGTH}</txt-record><txt-record>ip=${SERVER_IP}</txt-record>
</service></service-group>
EOF
  if ! $SUDO cmp -s "$tmp" /etc/avahi/services/local-ai.service 2>/dev/null; then $SUDO install -m0644 "$tmp" /etc/avahi/services/local-ai.service; $SUDO systemctl restart avahi-daemon; fi
  rm -f "$tmp"
  if command -v ufw >/dev/null && $SUDO ufw status|grep -q '^Status: active'; then
    $SUDO ufw allow from "$LAN_CIDR" to "$SERVER_IP" port "$GATEWAY_PORT" proto tcp >/dev/null
    $SUDO ufw allow from "$LAN_CIDR" to "$SERVER_IP" port 22 proto tcp >/dev/null
    $SUDO ufw allow 5353/udp >/dev/null
  else warn "UFW inactive; not enabled automatically"; fi
}

metadata(){
  local d="$INSTALL_HOME/.config/local-ai" t; $SUDO install -d -m0700 -o "$INSTALL_USER" -g "$INSTALL_GROUP" "$d"; t="$(mktemp)"
  cat >"$t"<<EOF
SERVER_IP=${SERVER_IP}
MODEL=${MODEL}
CONTEXT_LENGTH=${CONTEXT_LENGTH}
GATEWAY_PORT=${GATEWAY_PORT}
API_TOKEN=${TOKEN}
EOF
  $SUDO install -m0600 -o "$INSTALL_USER" -g "$INSTALL_GROUP" "$t" "$d/client.env"; rm -f "$t"
}

verify(){
  log "Verifying discovery + authenticated APIs..."
  curl -fsS "http://${SERVER_IP}:${GATEWAY_PORT}/auto-agent/discovery"|python3 -c 'import json,sys;d=json.load(sys.stdin);assert d["service"]=="auto_agent"'
  curl -fsS -H "Authorization: Bearer $TOKEN" "http://${SERVER_IP}:${GATEWAY_PORT}/api/tags" >/dev/null
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://${SERVER_IP}:${GATEWAY_PORT}/api/tags")" == 401 ]] || die "Unauthenticated API is not blocked"
  timeout 300 curl -fsS http://127.0.0.1:11434/api/chat -H 'Content-Type: application/json' -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply GPU_OK\"}],\"stream\":false}" >/dev/null
  log "Ollama accelerator placement:"; ollama ps|sed 's/^/  /'
}

preflight
ensure_driver
install_missing ca-certificates curl openssl python3 iproute2 pciutils nginx avahi-daemon avahi-utils openssh-server
network; log "LAN: $LAN_IF / $SERVER_IP / $LAN_CIDR"
ensure_ollama
select_model
token
gateway
discovery_ssh
metadata
verify

printf '\n============================================================\nAUTO_AGENT GPU SERVER READY\n'
printf 'GPU server : %s:%s\nModel      : %s\nReason     : %s\nContext    : %s\nDiscovery  : mDNS + HTTP subnet fallback\n' "$SERVER_IP" "$GATEWAY_PORT" "$MODEL" "$MODEL_REASON" "$CONTEXT_LENGTH"
printf '============================================================\n'
