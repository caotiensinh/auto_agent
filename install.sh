#!/usr/bin/env bash
set -Eeuo pipefail

# auto_agent one-command bootstrap.
# Same command on both Ubuntu machines:
#   curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | bash
#
# Auto role selection:
#   NVIDIA GPU present -> server
#   otherwise          -> client
# Override with ROLE=server or ROLE=client.

REPO_RAW="${AUTO_AGENT_REPO_RAW:-https://raw.githubusercontent.com/caotiensinh/auto_agent/main}"
ROLE="${ROLE:-auto}"

log()  { printf '\033[1;34m[auto_agent]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[auto_agent:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu is required. Detected: ${ID:-unknown}"
command -v curl >/dev/null 2>&1 || die "curl is required for the bootstrap command"

has_nvidia() {
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    return 0
  fi
  local f
  for f in /sys/bus/pci/devices/*/vendor; do
    [[ -r "$f" ]] || continue
    grep -qi '^0x10de$' "$f" && return 0
  done
  return 1
}

prepare_client_runtime_path() {
  local d found=""

  # Reuse user-scoped runtimes already installed by Hermes/OpenClaw.
  # This is especially important for curl|bash runs because the current shell
  # does not automatically reload ~/.bashrc after an installer updates PATH.
  for d in \
    "$HOME/.local/bin" \
    "$HOME/.hermes/bin" \
    "$HOME/.hermes/node/bin" \
    "$HOME/.openclaw/bin" \
    "$HOME/.volta/bin" \
    "$HOME/.nvm/current/bin"; do
    [[ -d "$d" ]] && PATH="$d:$PATH"
  done
  export PATH

  # If Node is present in a non-standard Hermes/user location, reuse it rather
  # than installing another Node copy.
  if ! command -v node >/dev/null 2>&1; then
    found="$(find "$HOME/.hermes" "$HOME/.local" -maxdepth 5 -type f -name node -perm -u+x -print -quit 2>/dev/null || true)"
    if [[ -n "$found" ]]; then
      PATH="$(dirname "$found"):$PATH"
      export PATH
    fi
  fi

  if command -v node >/dev/null 2>&1; then
    log "Node runtime: $(command -v node) ($(node --version 2>/dev/null || echo unknown)) [REUSE]"
  elif [[ -x "$HOME/.local/bin/openclaw" || -x "$HOME/.openclaw/bin/openclaw" ]]; then
    die "OpenClaw exists but no Node runtime was found. Refusing to reinstall blindly; inspect the existing Node installation."
  else
    log "Node runtime: not present yet; client installer may install it only if required"
  fi
}

case "$ROLE" in
  auto)
    if has_nvidia; then ROLE=server; else ROLE=client; fi
    ;;
  server|client) ;;
  *) die "ROLE must be auto, server, or client" ;;
esac

log "Ubuntu: ${PRETTY_NAME:-$VERSION_ID}"
log "Selected role: $ROLE"

if [[ "$ROLE" == "client" ]]; then
  prepare_client_runtime_path
fi

TMP="$(mktemp)"
SVC_TMP=""
trap 'rm -f "$TMP" "${SVC_TMP:-}"' EXIT

case "$ROLE" in
  server) TARGET="scripts/server.sh" ;;
  client) TARGET="scripts/client.sh" ;;
esac

log "Downloading ${TARGET} from caotiensinh/auto_agent..."
curl -fsSL --proto '=https' --tlsv1.2 "${REPO_RAW}/${TARGET}" -o "$TMP"
[[ -s "$TMP" ]] || die "Downloaded deployment script is empty"

# Basic corruption/route guard before execution.
grep -q '^#!/usr/bin/env bash' "$TMP" || die "Unexpected deployment script format"
grep -q 'AUTO_AGENT_COMPONENT=' "$TMP" || die "Downloaded file is not an auto_agent deployment component"
chmod 0700 "$TMP"

if [[ "$ROLE" == "server" ]]; then
  exec bash "$TMP"
fi

# Client deployment is two idempotent phases:
#   1) agent/model connectivity reconciliation
#   2) boot persistence + local control surfaces
bash "$TMP"

log "Downloading boot/control service reconciler..."
SVC_TMP="$(mktemp)"
curl -fsSL --proto '=https' --tlsv1.2 "${REPO_RAW}/scripts/client_services.sh" -o "$SVC_TMP"
[[ -s "$SVC_TMP" ]] || die "Downloaded client service script is empty"
grep -q '^#!/usr/bin/env bash' "$SVC_TMP" || die "Unexpected client service script format"
grep -q 'AUTO_AGENT_COMPONENT=client-services' "$SVC_TMP" || die "Downloaded file is not the auto_agent client service component"
chmod 0700 "$SVC_TMP"
exec bash "$SVC_TMP"
