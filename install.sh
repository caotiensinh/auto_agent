#!/usr/bin/env bash
set -Eeuo pipefail

# auto_agent one-command bootstrap.
# Same command on both Ubuntu machines:
#   curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | bash

REPO_RAW="${AUTO_AGENT_REPO_RAW:-https://raw.githubusercontent.com/caotiensinh/auto_agent/main}"
ROLE="${ROLE:-auto}"

log(){ printf '\033[1;34m[auto_agent]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[auto_agent:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "Ubuntu is required. Detected: ${ID:-unknown}"
command -v curl >/dev/null 2>&1 || die "curl is required for the bootstrap command"

has_nvidia(){
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then return 0; fi
  local f
  for f in /sys/bus/pci/devices/*/vendor; do
    [[ -r "$f" ]] || continue
    grep -qi '^0x10de$' "$f" && return 0
  done
  return 1
}

prepare_client_runtime_path(){
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
  if command -v node >/dev/null 2>&1; then
    log "Node runtime: $(command -v node) ($(node --version 2>/dev/null || echo unknown)) [REUSE]"
  elif [[ -x "$HOME/.local/bin/openclaw" || -x "$HOME/.openclaw/bin/openclaw" ]]; then
    die "OpenClaw exists but no Node runtime was found. Refusing to reinstall blindly."
  else
    log "Node runtime: not present yet; client installer may install it only if required"
  fi
}

download_component(){
  local path="$1" out="$2" marker="$3"
  curl -fsSL --proto '=https' --tlsv1.2 "${REPO_RAW}/${path}" -o "$out"
  [[ -s "$out" ]] || die "Downloaded ${path} is empty"
  grep -q '^#!/usr/bin/env bash' "$out" || die "Unexpected ${path} format"
  grep -q "$marker" "$out" || die "Downloaded ${path} failed component identity check"
  bash -n "$out" || die "Downloaded ${path} failed bash syntax validation"
  chmod 0700 "$out"
}

case "$ROLE" in
  auto) if has_nvidia; then ROLE=server; else ROLE=client; fi ;;
  server|client) ;;
  *) die "ROLE must be auto, server, or client" ;;
esac

log "Ubuntu: ${PRETTY_NAME:-$VERSION_ID}"
log "Selected role: $ROLE"
[[ "$ROLE" == client ]] && prepare_client_runtime_path

TMP="$(mktemp)"
SVC_TMP=""
UNIFIED_TMP=""
cleanup(){ rm -f "$TMP"; [[ -z "$SVC_TMP" ]] || rm -f "$SVC_TMP"; [[ -z "$UNIFIED_TMP" ]] || rm -f "$UNIFIED_TMP"; }
trap cleanup EXIT

if [[ "$ROLE" == server ]]; then
  log "Downloading scripts/server.sh from caotiensinh/auto_agent..."
  download_component scripts/server.sh "$TMP" 'AUTO_AGENT_COMPONENT=server'
  exec bash "$TMP"
fi

# Client phase 1: agent/model connectivity reconciliation.
log "Downloading scripts/client.sh from caotiensinh/auto_agent..."
download_component scripts/client.sh "$TMP" 'AUTO_AGENT_COMPONENT=client'
bash "$TMP"
prepare_client_runtime_path

# Client phase 2: boot persistence and loopback agent services.
SVC_TMP="$(mktemp)"
log "Downloading scripts/client_services.sh from caotiensinh/auto_agent..."
download_component scripts/client_services.sh "$SVC_TMP" 'AUTO_AGENT_COMPONENT=client-services'
LAN_CONTROL=0 bash "$SVC_TMP"

# Client phase 3: one authenticated LAN web UI for Hermes + OpenClaw.
UNIFIED_TMP="$(mktemp)"
log "Downloading scripts/unified_control.sh from caotiensinh/auto_agent..."
download_component scripts/unified_control.sh "$UNIFIED_TMP" 'AUTO_AGENT_COMPONENT=unified-control'
exec bash "$UNIFIED_TMP"
