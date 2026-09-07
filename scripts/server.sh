#!/usr/bin/env bash
set -Eeuo pipefail
AUTO_AGENT_COMPONENT=server

MODEL="${MODEL:-qwen3.5:9b}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-65536}"
KEEP_ALIVE="${KEEP_ALIVE:-20m}"
GATEWAY_PORT="${GATEWAY_PORT:-11434}"
ROTATE_TOKEN="${ROTATE_TOKEN:-0}"

log()  { printf '\033[1;34m[SERVER]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[SERVER:OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[SERVER:WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[SERVER:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu is required"

if [[ ${EUID} -eq 0 ]]; then
  SUDO=""
  INSTALL_USER="${SUDO_USER:-root}"
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required"
  SUDO="sudo"
  INSTALL_USER="${SUDO_USER:-$USER}"
fi

INSTALL_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
INSTALL_GROUP="$(id -gn "$INSTALL_USER")"
[[ -n "$INSTALL_HOME" ]] || die "Cannot determine home directory for $INSTALL_USER"

log "Installing base services..."
$SUDO apt-get update
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl jq openssl python3 iproute2 nginx \
  avahi-daemon avahi-utils openssh-server

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found. Install/fix the NVIDIA driver first."
nvidia-smi >/dev/null 2>&1 || die "NVIDIA driver cannot communicate with the GPU"
ok "NVIDIA stack is operational"
nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader | sed 's/^/  /'

DEFAULT_ROUTE="$(ip -4 route show default | head -n1)"
LAN_IF="$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$DEFAULT_ROUTE")"
LAN_ADDR="$(ip -o -4 addr show dev "$LAN_IF" scope global | awk 'NR==1{print $4}')"
[[ -n "$LAN_ADDR" ]] || die "Cannot detect LAN IPv4 address"
SERVER_IP="${LAN_ADDR%/*}"
LAN_CIDR="$(python3 - "$LAN_ADDR" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"

log "LAN interface: $LAN_IF"
log "Server IP: $SERVER_IP"
log "Allowed subnet: $LAN_CIDR"

log "Installing/updating Ollama..."
curl -fsSL https://ollama.com/install.sh | sh
command -v ollama >/dev/null 2>&1 || die "Ollama installation failed"

log "Configuring Ollama localhost-only service..."
$SUDO install -d -m 0755 /etc/systemd/system/ollama.service.d
TMP_OVERRIDE="$(mktemp)"
cat >"$TMP_OVERRIDE" <<EOF
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_CONTEXT_LENGTH=${CONTEXT_LENGTH}"
Environment="OLLAMA_KEEP_ALIVE=${KEEP_ALIVE}"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
EOF
$SUDO install -m 0644 "$TMP_OVERRIDE" /etc/systemd/system/ollama.service.d/10-auto-agent.conf
rm -f "$TMP_OVERRIDE"
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now ollama
$SUDO systemctl restart ollama

log "Waiting for Ollama API..."
for _ in $(seq 1 60); do
  curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null || die "Ollama did not become ready"

log "Pulling model: $MODEL"
ollama pull "$MODEL"

log "Creating/reusing API token..."
$SUDO install -d -m 0700 /etc/local-ai-gateway
TOKEN_FILE=/etc/local-ai-gateway/token
if [[ "$ROTATE_TOKEN" == "1" || ! -s "$TOKEN_FILE" ]]; then
  TOKEN="$(openssl rand -hex 32)"
  printf '%s\n' "$TOKEN" | $SUDO tee "$TOKEN_FILE" >/dev/null
  $SUDO chmod 0600 "$TOKEN_FILE"
  $SUDO chown root:root "$TOKEN_FILE"
else
  TOKEN="$($SUDO cat "$TOKEN_FILE")"
fi
[[ "$TOKEN" =~ ^[A-Fa-f0-9]{64}$ ]] || die "Invalid API token state"

log "Configuring authenticated Nginx gateway..."
TMP_NGINX="$(mktemp)"
cat >"$TMP_NGINX" <<EOF
# Managed by caotiensinh/auto_agent
server {
    listen ${SERVER_IP}:${GATEWAY_PORT};
    server_name _;
    access_log /var/log/nginx/local-ai-access.log;
    error_log /var/log/nginx/local-ai-error.log warn;
    client_max_body_size 200m;

    location / {
        allow ${LAN_CIDR};
        allow 127.0.0.1;
        deny all;

        if (\$http_authorization != "Bearer ${TOKEN}") { return 401; }

        proxy_pass http://127.0.0.1:11434;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_set_header Host \$host;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
$SUDO install -m 0600 "$TMP_NGINX" /etc/nginx/conf.d/local-ai-gateway.conf
rm -f "$TMP_NGINX"
$SUDO nginx -t
$SUDO systemctl enable --now nginx
$SUDO systemctl reload nginx

log "Enabling SSH and mDNS discovery..."
$SUDO systemctl enable --now ssh
$SUDO systemctl enable --now avahi-daemon
TMP_AVAHI="$(mktemp)"
cat >"$TMP_AVAHI" <<EOF
<?xml version="1.0" standalone="no"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Local AI GPU on %h</name>
  <service>
    <type>_local-ai._tcp</type>
    <port>${GATEWAY_PORT}</port>
    <txt-record>ssh_user=${INSTALL_USER}</txt-record>
    <txt-record>model=${MODEL}</txt-record>
    <txt-record>context=${CONTEXT_LENGTH}</txt-record>
    <txt-record>api=ollama+openai</txt-record>
  </service>
</service-group>
EOF
$SUDO install -m 0644 "$TMP_AVAHI" /etc/avahi/services/local-ai.service
rm -f "$TMP_AVAHI"
$SUDO systemctl restart avahi-daemon

if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q '^Status: active'; then
  log "UFW active: adding LAN-only rules"
  $SUDO ufw allow from "$LAN_CIDR" to "$SERVER_IP" port "$GATEWAY_PORT" proto tcp
  $SUDO ufw allow from "$LAN_CIDR" to "$SERVER_IP" port 22 proto tcp
  $SUDO ufw allow 5353/udp
else
  warn "UFW is not active; it was not enabled automatically"
fi

log "Writing client metadata for secure SSH retrieval..."
CLIENT_DIR="$INSTALL_HOME/.config/local-ai"
$SUDO install -d -m 0700 -o "$INSTALL_USER" -g "$INSTALL_GROUP" "$CLIENT_DIR"
TMP_ENV="$(mktemp)"
cat >"$TMP_ENV" <<EOF
MODEL=${MODEL}
CONTEXT_LENGTH=${CONTEXT_LENGTH}
GATEWAY_PORT=${GATEWAY_PORT}
API_TOKEN=${TOKEN}
EOF
$SUDO install -m 0600 -o "$INSTALL_USER" -g "$INSTALL_GROUP" "$TMP_ENV" "$CLIENT_DIR/client.env"
rm -f "$TMP_ENV"

log "Running API smoke tests..."
curl -fsS --max-time 10 -H "Authorization: Bearer ${TOKEN}" \
  "http://${SERVER_IP}:${GATEWAY_PORT}/api/tags" | jq -e '.models|type=="array"' >/dev/null \
  || die "Native Ollama gateway test failed"
curl -fsS --max-time 10 -H "Authorization: Bearer ${TOKEN}" \
  "http://${SERVER_IP}:${GATEWAY_PORT}/v1/models" | jq -e '.data|type=="array"' >/dev/null \
  || die "OpenAI-compatible gateway test failed"
HTTP_CODE="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://${SERVER_IP}:${GATEWAY_PORT}/api/tags" || true)"
[[ "$HTTP_CODE" == "401" ]] || warn "Expected HTTP 401 without token, got $HTTP_CODE"

printf '\n============================================================\n'
printf 'AUTO_AGENT GPU SERVER READY\n'
printf 'Host            : %s.local\n' "$(hostname -s)"
printf 'IP              : %s\n' "$SERVER_IP"
printf 'Subnet          : %s\n' "$LAN_CIDR"
printf 'Model           : %s\n' "$MODEL"
printf 'Context         : %s\n' "$CONTEXT_LENGTH"
printf 'Gateway         : http://%s:%s\n' "$SERVER_IP" "$GATEWAY_PORT"
printf 'Ollama backend  : 127.0.0.1:11434 only\n'
printf 'Token           : generated automatically; not printed\n'
printf 'Discovery       : _local-ai._tcp via mDNS\n'
printf '============================================================\n'
printf 'Next: run the same one-line installer on the Ubuntu laptop.\n'
