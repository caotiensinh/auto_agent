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

case "$ROLE" in
  auto)
    if has_nvidia; then ROLE=server; else ROLE=client; fi
    ;;
  server|client) ;;
  *) die "ROLE must be auto, server, or client" ;;
esac

log "Ubuntu: ${PRETTY_NAME:-$VERSION_ID}"
log "Selected role: $ROLE"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

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
exec bash "$TMP"
