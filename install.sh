#!/usr/bin/env bash
set -Eeuo pipefail

AUTO_AGENT_BOOTSTRAP_VERSION="0.5.2"
REPO_RAW="${AUTO_AGENT_REPO_RAW:-https://raw.githubusercontent.com/caotiensinh/auto_agent/main}"
ROLE="${ROLE:-auto}"

log(){ printf '\033[1;34m[auto_agent]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[auto_agent:OK]\033[0m %s\n' "$*"; }
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
  local path="$1" out="$2" marker="$3" bust url
  bust="$(date +%s%N 2>/dev/null || date +%s)"
  url="${REPO_RAW}/${path}?auto_agent_cache_bust=${bust}"
  curl -fsSL --proto '=https' --tlsv1.2 \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "$url" -o "$out"
  [[ -s "$out" ]] || die "Downloaded ${path} is empty"
  grep -q '^#!/usr/bin/env bash' "$out" || die "Unexpected ${path} format"
  grep -q "$marker" "$out" || die "Downloaded ${path} failed component identity check"
  bash -n "$out" || die "Downloaded ${path} failed bash syntax validation"
  chmod 0700 "$out"
}

# IMPORTANT: when install.sh itself is executed as `curl ... | bash`, stdin is the
# source-code pipe. A child program that reads stdin can otherwise consume the
# unread remainder of this bootstrap and make phase 2/3 disappear. Components
# therefore receive the controlling terminal (or /dev/null when no tty exists),
# never the bootstrap source stream.
run_bash_component(){
  local file="$1"; shift
  if [[ -r /dev/tty ]]; then
    env "$@" bash "$file" </dev/tty
  else
    env "$@" bash "$file" </dev/null
  fi
}

case "$ROLE" in
  auto) if has_nvidia; then ROLE=server; else ROLE=client; fi ;;
  server|client) ;;
  *) die "ROLE must be auto, server, or client" ;;
esac

if [[ -t 0 ]]; then BOOTSTRAP_INPUT="terminal"; else BOOTSTRAP_INPUT="stream-isolated"; fi
printf '\n============================================================\n'
printf 'AUTO_AGENT BOOTSTRAP\n'
printf 'Version : %s\n' "$AUTO_AGENT_BOOTSTRAP_VERSION"
printf 'Ubuntu  : %s\n' "${PRETTY_NAME:-$VERSION_ID}"
printf 'Role    : %s\n' "$ROLE"
printf 'Input   : %s\n' "$BOOTSTRAP_INPUT"
printf '============================================================\n\n'

[[ "$ROLE" == client ]] && prepare_client_runtime_path

TMP="$(mktemp)"
SVC_TMP=""
UNIFIED_TMP=""
cleanup(){
  rm -f "$TMP"
  [[ -z "$SVC_TMP" ]] || rm -f "$SVC_TMP"
  [[ -z "$UNIFIED_TMP" ]] || rm -f "$UNIFIED_TMP"
}
trap cleanup EXIT

if [[ "$ROLE" == server ]]; then
  log "SERVER PHASE — inventory/reuse/configure/verify"
  download_component scripts/server.sh "$TMP" 'AUTO_AGENT_COMPONENT=server'
  run_bash_component "$TMP"
  exit 0
fi

log "CLIENT PHASE 1/3 — agent + GPU connectivity reconciliation"
download_component scripts/client.sh "$TMP" 'AUTO_AGENT_COMPONENT=client'
run_bash_component "$TMP"
ok "CLIENT PHASE 1/3 completed"
prepare_client_runtime_path

SVC_TMP="$(mktemp)"
log "CLIENT PHASE 2/3 — boot persistence + loopback agent services"
download_component scripts/client_services.sh "$SVC_TMP" 'AUTO_AGENT_COMPONENT=client-services'
run_bash_component "$SVC_TMP" LAN_CONTROL=0
ok "CLIENT PHASE 2/3 completed"

UNIFIED_TMP="$(mktemp)"
log "CLIENT PHASE 3/3 — authenticated unified LAN Control Center"
download_component scripts/unified_control.sh "$UNIFIED_TMP" 'AUTO_AGENT_COMPONENT=unified-control'
run_bash_component "$UNIFIED_TMP"
ok "CLIENT PHASE 3/3 completed"
