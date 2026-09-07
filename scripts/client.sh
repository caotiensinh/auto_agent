#!/usr/bin/env bash
set -Eeuo pipefail
AUTO_AGENT_COMPONENT=client

CONTEXT_LENGTH="${CONTEXT_LENGTH:-65536}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

log()  { printf '\033[1;34m[CLIENT]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[CLIENT:OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[CLIENT:WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[CLIENT:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -ne 0 ]] || die "Run client deployment as your normal Ubuntu user, not root"
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu is required"
command -v sudo >/dev/null 2>&1 || die "sudo is required"

log "Installing client prerequisites..."
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl jq python3 python3-yaml avahi-daemon avahi-utils openssh-client
sudo systemctl enable --now avahi-daemon

log "Discovering Local AI GPU server over mDNS..."
BROWSE="$(timeout 25 avahi-browse -rtp _local-ai._tcp 2>/dev/null || true)"
LINE="$(awk -F';' '$1=="=" && $3=="IPv4" {print; exit}' <<<"$BROWSE")"
[[ -n "$LINE" ]] || die "No _local-ai._tcp server found. Run the installer on the NVIDIA GPU PC first and keep both machines on the same LAN/VLAN."

IFS=';' read -r _ _ _ SERVICE_NAME SERVICE_TYPE DOMAIN SERVER_HOST SERVER_IP SERVER_PORT TXT <<<"$LINE"
[[ -n "$SERVER_HOST" && -n "$SERVER_IP" && -n "$SERVER_PORT" ]] || die "Incomplete mDNS result"
SSH_USER="$(sed -nE 's/.*"ssh_user=([^\"]+)".*/\1/p' <<<"$TXT" | head -n1)"
DISCOVERED_MODEL="$(sed -nE 's/.*"model=([^\"]+)".*/\1/p' <<<"$TXT" | head -n1)"
[[ -n "$SSH_USER" ]] || SSH_USER="$USER"

log "GPU server found:"
log "  host : $SERVER_HOST"
log "  ip   : $SERVER_IP"
log "  port : $SERVER_PORT"
log "  user : $SSH_USER"
[[ -n "$DISCOVERED_MODEL" ]] && log "  model: $DISCOVERED_MODEL"

mkdir -p "$HOME/.ssh"
chmod 0700 "$HOME/.ssh"
if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
  PUBKEY="$HOME/.ssh/id_ed25519.pub"
elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
  PUBKEY="$HOME/.ssh/id_rsa.pub"
else
  log "Creating SSH key for secure pairing..."
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519"
  PUBKEY="$HOME/.ssh/id_ed25519.pub"
fi

SSH_TARGET="${SSH_USER}@${SERVER_HOST}"
SSH_OPTS=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$SSH_TARGET" true >/dev/null 2>&1; then
  warn "First secure pairing requires the GPU-server Ubuntu password once."
  ssh-copy-id "${SSH_OPTS[@]}" -i "$PUBKEY" "$SSH_TARGET" || die "SSH pairing failed"
fi
ok "SSH trust established"

log "Retrieving generated connection secret through SSH..."
REMOTE_ENV="$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'cat ~/.config/local-ai/client.env')" || die "Cannot retrieve server metadata"
TOKEN="$(grep -m1 '^API_TOKEN=' <<<"$REMOTE_ENV" | cut -d= -f2-)"
MODEL="$(grep -m1 '^MODEL=' <<<"$REMOTE_ENV" | cut -d= -f2-)"
REMOTE_CONTEXT="$(grep -m1 '^CONTEXT_LENGTH=' <<<"$REMOTE_ENV" | cut -d= -f2-)"
REMOTE_PORT="$(grep -m1 '^GATEWAY_PORT=' <<<"$REMOTE_ENV" | cut -d= -f2-)"
[[ "$TOKEN" =~ ^[A-Fa-f0-9]{64}$ ]] || die "Invalid API token returned by server"
[[ -n "$MODEL" ]] || MODEL="${DISCOVERED_MODEL:-qwen3.5:9b}"
[[ "$REMOTE_CONTEXT" =~ ^[0-9]+$ ]] && CONTEXT_LENGTH="$REMOTE_CONTEXT"
[[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] && SERVER_PORT="$REMOTE_PORT"

OLLAMA_URL="http://${SERVER_HOST}:${SERVER_PORT}"
OPENAI_URL="${OLLAMA_URL}/v1"
mkdir -p "$HOME/.config/local-ai"
chmod 0700 "$HOME/.config/local-ai"
cat >"$HOME/.config/local-ai/server.env" <<EOF
SERVER_HOST=${SERVER_HOST}
SERVER_IP=${SERVER_IP}
GATEWAY_PORT=${SERVER_PORT}
MODEL=${MODEL}
CONTEXT_LENGTH=${CONTEXT_LENGTH}
API_TOKEN=${TOKEN}
OLLAMA_BASE_URL=${OLLAMA_URL}
OPENAI_BASE_URL=${OPENAI_URL}
EOF
chmod 0600 "$HOME/.config/local-ai/server.env"

log "Testing authenticated GPU APIs..."
curl -fsS --connect-timeout 5 --max-time 20 -H "Authorization: Bearer ${TOKEN}" \
  "${OLLAMA_URL}/api/tags" | jq -e '.models|type=="array"' >/dev/null || die "Ollama native API test failed"
curl -fsS --connect-timeout 5 --max-time 20 -H "Authorization: Bearer ${TOKEN}" \
  "${OPENAI_URL}/models" | jq -e '.data|type=="array"' >/dev/null || die "OpenAI-compatible API test failed"
ok "GPU inference gateway reachable"

log "Installing/updating Hermes Agent..."
HERMES_INSTALLER="$(mktemp)"
curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o "$HERMES_INSTALLER"
bash "$HERMES_INSTALLER" --non-interactive --skip-setup
rm -f "$HERMES_INSTALLER"
export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"

HERMES_CMD="$(command -v hermes 2>/dev/null || true)"
for C in "$HOME/.local/bin/hermes" "$HOME/.hermes/bin/hermes" "$HOME/.hermes/hermes-agent/venv/bin/hermes"; do
  [[ -n "$HERMES_CMD" ]] && break
  [[ -x "$C" ]] && HERMES_CMD="$C"
done
[[ -n "$HERMES_CMD" ]] || die "Hermes installed but executable not found"

log "Configuring Hermes remote OpenAI-compatible endpoint..."
mkdir -p "$HERMES_HOME"
chmod 0700 "$HERMES_HOME"
HERMES_CONFIG="$HERMES_HOME/config.yaml"
[[ -f "$HERMES_CONFIG" ]] && cp -a "$HERMES_CONFIG" "${HERMES_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
python3 - "$HERMES_CONFIG" "$MODEL" "$OPENAI_URL" "$TOKEN" "$CONTEXT_LENGTH" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1])
model, base_url, api_key, context = sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
cfg = {}
if p.exists() and p.read_text(encoding='utf-8').strip():
    loaded = yaml.safe_load(p.read_text(encoding='utf-8'))
    if loaded is not None:
        if not isinstance(loaded, dict):
            raise SystemExit('Existing Hermes config root is not a mapping')
        cfg = loaded
m = cfg.get('model')
if not isinstance(m, dict):
    m = {}
    cfg['model'] = m
m.update({'default': model, 'provider': 'custom', 'base_url': base_url,
          'api_key': api_key, 'context_length': context})
tmp = p.with_suffix('.yaml.tmp')
tmp.write_text(yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True), encoding='utf-8')
tmp.replace(p)
PY
chmod 0600 "$HERMES_CONFIG"

log "Smoke-testing remote inference for Hermes..."
RESP="$(mktemp)"
timeout 300 curl -fsS "${OPENAI_URL}/chat/completions" \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg model "$MODEL" '{model:$model,messages:[{role:"user",content:"Reply with exactly: HERMES_OK"}],max_tokens:32,stream:false}')" >"$RESP" \
  || die "Remote inference test failed"
jq -e '.choices[0].message.content' "$RESP" >/dev/null || die "Unexpected inference response"
rm -f "$RESP"
ok "Hermes inference path ready"

log "Installing/updating OpenClaw..."
curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | \
  bash -s -- --no-prompt --no-onboard --verify
export PATH="$HOME/.local/bin:$HOME/.openclaw/bin:$PATH"
OPENCLAW_CMD="$(command -v openclaw 2>/dev/null || true)"
for C in "$HOME/.local/bin/openclaw" "$HOME/.openclaw/bin/openclaw"; do
  [[ -n "$OPENCLAW_CMD" ]] && break
  [[ -x "$C" ]] && OPENCLAW_CMD="$C"
done
[[ -n "$OPENCLAW_CMD" ]] || die "OpenClaw installed but executable not found"

log "Creating OpenClaw baseline and configuring remote Ollama provider..."
"$OPENCLAW_CMD" setup --baseline >/dev/null
"$OPENCLAW_CMD" config set models.providers.ollama.baseUrl "$OLLAMA_URL"
"$OPENCLAW_CMD" config set models.providers.ollama.api "ollama"
"$OPENCLAW_CMD" config set models.providers.ollama.apiKey "$TOKEN"
"$OPENCLAW_CMD" models set "ollama/${MODEL}"
"$OPENCLAW_CMD" config set tools.profile "messaging"
"$OPENCLAW_CMD" config set agents.defaults.heartbeat.every "0m"
"$OPENCLAW_CMD" config set gateway.mode "local"
[[ -f "$HOME/.openclaw/openclaw.json" ]] && chmod 0600 "$HOME/.openclaw/openclaw.json" || true

log "Installing/restarting OpenClaw Gateway service..."
"$OPENCLAW_CMD" gateway install --force
"$OPENCLAW_CMD" gateway restart || true
"$OPENCLAW_CMD" models list --provider ollama >/dev/null || die "OpenClaw Ollama provider verification failed"
"$OPENCLAW_CMD" doctor >/dev/null || warn "OpenClaw doctor reported warnings; run: openclaw doctor"

printf '\n============================================================\n'
printf 'AUTO_AGENT LAPTOP READY\n'
printf 'GPU server       : %s (%s)\n' "$SERVER_HOST" "$SERVER_IP"
printf 'Model            : %s\n' "$MODEL"
printf 'Hermes endpoint  : %s\n' "$OPENAI_URL"
printf 'OpenClaw Ollama  : %s\n' "$OLLAMA_URL"
printf 'Hermes           : %s\n' "$HERMES_CMD"
printf 'OpenClaw         : %s\n' "$OPENCLAW_CMD"
printf 'Token            : transferred automatically over SSH; not printed\n'
printf 'OpenClaw policy  : messaging profile; heartbeat disabled\n'
printf '============================================================\n'
printf 'Hermes:    %s\n' "$HERMES_CMD"
printf 'OpenClaw:  %s status\n' "$OPENCLAW_CMD"
printf 'Dashboard: %s dashboard\n' "$OPENCLAW_CMD"
