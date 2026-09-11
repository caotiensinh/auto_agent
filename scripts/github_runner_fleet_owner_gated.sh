#!/usr/bin/env bash
set -Eeuo pipefail

# GitHub Personal Account Multi-Repo Self-Hosted Runner Installer
# Default owner: caotiensinh
#
# Purpose:
# - Ask for ONE GitHub PAT.
# - Discover repositories owned by the personal account.
# - Create a short-lived registration token for each repository.
# - Install/reinstall a configurable pool of self-hosted runner workers per repository.
# - Default: private, non-archived repositories only.
#
# Security:
# - PAT is read silently and never written to disk by this script.
# - Every runner is protected by a root-owned pre-job OWNER GATE.
# - Public repositories are excluded by default because self-hosted runners
#   can execute repository workflow code on this machine.
#
# Requirements:
# - Ubuntu/Debian-like Linux with systemd
# - curl, tar, python3
# - sudo access
#
# Recommended PAT:
# - Classic PAT: repo scope (simple for all private repos you own), OR
# - Fine-grained PAT: access to the selected repos + Administration: Read/Write.
#
# Examples:
#   bash github_runner_fleet_owner_gated.sh --repo workspace --workers 20
#   bash github_runner_fleet_owner_gated.sh --include-public --workers 2
#   bash github_runner_fleet_owner_gated.sh --dry-run --workers 10

OWNER="caotiensinh"
ROOT_DIR="/opt/github-runners"
SECURITY_DIR="/etc/github-runner-security"
RUNNER_USER="github-runner"
WORK_DIR="_work"
CUSTOM_LABELS="trusted,owner-gated,personal-fleet"
INCLUDE_PUBLIC=0
DRY_RUN=0
ONLY_REPO=""
WORKERS=1
REINSTALL=1
KEEP_FAILED_DIR=1

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
GitHub personal-account multi-repo self-hosted runner installer

Options:
  --owner NAME          GitHub personal account owner (default: caotiensinh)
  --root DIR            Runner root directory (default: /opt/github-runners)
  --repo NAME           Install/reinstall only one repository
  --workers N           Parallel runner workers per selected repository (default: 1)
  --include-public      Also install runners for public repositories (RISKY)
  --no-reinstall        Skip workers that are already configured
  --dry-run             Discover and show actions without changing the machine
  -h, --help            Show this help

Default behavior:
  - private repositories only unless --include-public is explicitly used
  - archived repos skipped
  - every runner is protected by a root-owned pre-job OWNER GATE
  - only the authenticated GitHub account numeric actor ID is admitted
  - repository identity must match the runner's root-owned allowlist entry
  - runner services use a dedicated non-login OS account with no intended sudo access
  - each worker has its own runner directory, work directory, name, and systemd service
  - unrelated runner directories outside ROOT_DIR are never touched
EOF
}

while (($#)); do
  case "$1" in
    --owner) OWNER="${2:?missing owner}"; shift 2 ;;
    --root) ROOT_DIR="${2:?missing root dir}"; shift 2 ;;
    --repo) ONLY_REPO="${2:?missing repo name}"; shift 2 ;;
    --workers) WORKERS="${2:?missing worker count}"; shift 2 ;;
    --include-public) INCLUDE_PUBLIC=1; shift ;;
    --no-reinstall) REINSTALL=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$(id -u)" -ne 0 ]] || die "Do not run this script directly as root. Run as your normal Linux user; the installer will use sudo for hardened system files."
[[ "$WORKERS" =~ ^[1-9][0-9]*$ ]] || die "--workers must be a positive integer."
(( WORKERS <= 64 )) || die "--workers above 64 is blocked by this installer. Scale deliberately."

for cmd in curl tar python3 uname hostname; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done
command -v sudo >/dev/null 2>&1 || die "sudo is required."

case "$(uname -s)" in Linux) ;; *) die "Linux only." ;; esac
case "$(uname -m)" in
  x86_64|amd64) RUNNER_ARCH="x64" ;;
  aarch64|arm64) RUNNER_ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

sudo -v
sudo mkdir -p "$ROOT_DIR" "$SECURITY_DIR/runners"
sudo chmod 755 "$ROOT_DIR" "$SECURITY_DIR" "$SECURITY_DIR/runners"

if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  log "Creating dedicated OS account: $RUNNER_USER"
  sudo useradd --system --create-home --home-dir "/var/lib/${RUNNER_USER}" --shell /usr/sbin/nologin "$RUNNER_USER"
fi

if sudo -u "$RUNNER_USER" sudo -n true >/dev/null 2>&1; then
  die "SECURITY BLOCK: '$RUNNER_USER' has passwordless sudo."
fi

printf '\n'
echo "============================================================"
echo " GitHub Self-Hosted Runner Fleet Installer"
echo "============================================================"
echo "Owner             : $OWNER"
echo "Root              : $ROOT_DIR"
echo "Architecture      : $RUNNER_ARCH"
echo "Runner OS account : $RUNNER_USER"
echo "Security gate     : root-owned pre-job actor/repository admission"
echo "Repository policy : $([[ "$INCLUDE_PUBLIC" -eq 1 ]] && echo 'private + PUBLIC' || echo 'PRIVATE ONLY')"
echo "Workers/repo      : $WORKERS"
echo "Reinstall         : $([[ "$REINSTALL" -eq 1 ]] && echo yes || echo no)"
echo "Dry-run           : $([[ "$DRY_RUN" -eq 1 ]] && echo yes || echo no)"
echo "============================================================"

if [[ "$INCLUDE_PUBLIC" -eq 1 ]]; then
  warn "PUBLIC repositories are enabled."
  warn "The local OWNER GATE will reject jobs whose GitHub actor ID is not the authenticated owner."
  read -r -p "Type I_ACCEPT_PUBLIC_RUNNER_RISK to continue: " ACK
  [[ "$ACK" == "I_ACCEPT_PUBLIC_RUNNER_RISK" ]] || die "Cancelled."
fi

echo "Paste a GitHub PAT with repository Administration write access."
read -r -s -p "GitHub PAT: " GH_PAT
echo
[[ -n "$GH_PAT" ]] || die "Empty token."
cleanup() { unset GH_PAT || true; }
trap cleanup EXIT

api() {
  local method="$1" url="$2"; shift 2
  curl -fsS -X "$method" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@" "$url"
}

log "Validating token..."
USER_JSON="$(api GET "https://api.github.com/user")" || die "GitHub authentication failed."
LOGIN="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("login",""))' <<<"$USER_JSON")"
OWNER_ACTOR_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$USER_JSON")"
[[ -n "$LOGIN" && "$OWNER_ACTOR_ID" =~ ^[0-9]+$ ]] || die "Could not resolve GitHub identity."
ok "Authenticated as: $LOGIN (ID $OWNER_ACTOR_ID)"
[[ "$LOGIN" == "$OWNER" ]] || die "Authenticated account '$LOGIN' does not match required owner '$OWNER'."

OWNER_GATE="${SECURITY_DIR}/owner_gate.sh"
if [[ "$DRY_RUN" -eq 0 ]]; then
  TMP_GATE="$(mktemp)"
  cat > "$TMP_GATE" <<'OWNER_GATE_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

deny() { printf '[OWNER-GATE] DENY: %s\n' "$*" >&2; exit 97; }
allow() { printf '[OWNER-GATE] ALLOW actor_id=%s repository=%s event=%s runner=%s\n' "${GITHUB_ACTOR_ID:-?}" "${GITHUB_REPOSITORY:-?}" "${GITHUB_EVENT_NAME:-?}" "${RUNNER_NAME:-?}"; exit 0; }

[[ "${GITHUB_ACTIONS:-}" == "true" ]] || deny "not a GitHub Actions job"
[[ "${RUNNER_ENVIRONMENT:-}" == "self-hosted" ]] || deny "not self-hosted"
runner_name="${RUNNER_NAME:-}"
[[ -n "$runner_name" ]] || deny "RUNNER_NAME missing"
safe_runner_name="${runner_name//[^A-Za-z0-9._-]/-}"
conf="/etc/github-runner-security/runners/${safe_runner_name}.conf"
[[ -r "$conf" ]] || deny "runner policy missing"
# shellcheck disable=SC1090
source "$conf"
[[ "${GITHUB_ACTOR_ID:-}" == "$OWNER_ACTOR_ID" ]] || deny "unauthorized actor ${GITHUB_ACTOR:-unknown} (${GITHUB_ACTOR_ID:-missing})"
[[ "${GITHUB_REPOSITORY:-}" == "$EXPECTED_REPOSITORY" ]] || deny "unexpected repository ${GITHUB_REPOSITORY:-missing}"
case "${GITHUB_ACTOR:-}" in dependabot\[bot\]|github-actions\[bot\]|renovate\[bot\]) deny "bot actor denied" ;; esac
allow
OWNER_GATE_EOF
  sudo install -o root -g root -m 0755 "$TMP_GATE" "$OWNER_GATE"
  rm -f "$TMP_GATE"
fi

log "Resolving latest GitHub Actions runner release..."
RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/actions/runner/releases/latest")"
RUNNER_VERSION="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))' <<<"$RELEASE_JSON")"
ASSET="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${ASSET}"
CACHE_DIR="${ROOT_DIR}/.cache"
ARCHIVE="${CACHE_DIR}/${ASSET}"
sudo mkdir -p "$CACHE_DIR"
sudo chmod 755 "$CACHE_DIR"
if ! sudo test -s "$ARCHIVE"; then
  TMP_ARCHIVE="$(mktemp)"
  curl -fL --retry 3 --retry-delay 2 -o "$TMP_ARCHIVE" "$DOWNLOAD_URL"
  sudo mv "$TMP_ARCHIVE" "$ARCHIVE"
  sudo chown root:root "$ARCHIVE"
  sudo chmod 644 "$ARCHIVE"
fi

REPO_TSV="$(mktemp)"
trap 'rm -f "$REPO_TSV"; cleanup' EXIT
page=1
while :; do
  JSON="$(api GET "https://api.github.com/user/repos?per_page=100&page=${page}&affiliation=owner&sort=full_name")"
  COUNT="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"$JSON")"
  [[ "$COUNT" -gt 0 ]] || break
  PAGE_JSON="$(mktemp)"
  printf '%s' "$JSON" > "$PAGE_JSON"
  python3 - "$OWNER" "$INCLUDE_PUBLIC" "$ONLY_REPO" "$PAGE_JSON" >>"$REPO_TSV" <<'PY'
import json, sys
owner, include_public, only_repo, json_path = sys.argv[1], sys.argv[2] == "1", sys.argv[3], sys.argv[4]
with open(json_path, encoding="utf-8") as f: repos = json.load(f)
for r in repos:
    if r.get("owner", {}).get("login") != owner or r.get("archived"): continue
    if only_repo and r.get("name") != only_repo: continue
    if not include_public and not r.get("private", False): continue
    print("\t".join([r.get("name", ""), "private" if r.get("private", False) else "public", r.get("default_branch") or ""]))
PY
  rm -f "$PAGE_JSON"
  ((page++))
done

[[ -s "$REPO_TSV" ]] || die "No matching repositories found."
TOTAL="$(wc -l < "$REPO_TSV" | tr -d ' ')"
log "Repositories selected: $TOTAL"
while IFS=$'\t' read -r repo visibility branch; do printf '  - %-40s %-8s default=%s\n' "$repo" "$visibility" "$branch"; done < "$REPO_TSV"

if [[ "$DRY_RUN" -eq 0 ]]; then
  read -r -p "Proceed with installation/reinstallation? [y/N]: " PROCEED
  [[ "${PROCEED,,}" == "y" ]] || die "Cancelled."
fi

HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
SUCCESS=0 FAILED=0 SKIPPED=0

remove_existing_runner_dir() {
  local repo="$1" runner_dir="$2" runner_name="$3"
  [[ -d "$runner_dir" ]] || return 0

  if [[ -f "${runner_dir}/.runner" ]]; then
    log "Existing runner detected: ${runner_name}"
    if [[ "$REINSTALL" -eq 0 ]]; then return 10; fi

    if [[ -x "${runner_dir}/svc.sh" ]]; then
      (cd "$runner_dir" && sudo ./svc.sh stop >/dev/null 2>&1) || true
      (cd "$runner_dir" && sudo ./svc.sh uninstall >/dev/null 2>&1) || true
    fi

    local remove_json remove_token
    remove_json="$(api POST "https://api.github.com/repos/${OWNER}/${repo}/actions/runners/remove-token")" || true
    remove_token="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token",""))' <<<"${remove_json:-{}}")"
    if [[ -n "$remove_token" && -x "${runner_dir}/config.sh" ]]; then
      (cd "$runner_dir" && sudo -u "$RUNNER_USER" ./config.sh remove --token "$remove_token" >/dev/null 2>&1) || true
    fi
  fi

  sudo rm -rf "$runner_dir"
  sudo rm -f "${SECURITY_DIR}/runners/${runner_name}.conf"
}

install_one_worker() {
  local repo="$1" visibility="$2" worker_index="$3"
  local worker_id
  printf -v worker_id "%02d" "$worker_index"

  local repo_root="${ROOT_DIR}/${repo}"
  local runner_dir="${repo_root}/worker-${worker_id}"
  local runner_name="${HOST_SHORT}-${repo}-w${worker_id}"
  runner_name="${runner_name//[^A-Za-z0-9._-]/-}"
  runner_name="${runner_name:0:63}"

  echo
  echo "------------------------------------------------------------"
  log "Repository : ${OWNER}/${repo} (${visibility})"
  log "Worker     : ${worker_id}/${WORKERS}"
  log "Runner name: ${runner_name}"
  log "Directory  : ${runner_dir}"

  if [[ "$worker_index" -eq 1 && -f "${repo_root}/.runner" ]]; then
    local legacy_name="${HOST_SHORT}-${repo}"
    legacy_name="${legacy_name//[^A-Za-z0-9._-]/-}"
    legacy_name="${legacy_name:0:63}"
    warn "${repo}: legacy single-runner layout detected; migrating it."
    remove_existing_runner_dir "$repo" "$repo_root" "$legacy_name" || true
  fi

  if [[ -f "${runner_dir}/.runner" ]]; then
    if [[ "$REINSTALL" -eq 0 ]]; then
      warn "${repo}/worker-${worker_id}: existing runner skipped (--no-reinstall)."
      ((SKIPPED+=1)); return 0
    fi
    remove_existing_runner_dir "$repo" "$runner_dir" "$runner_name" || true
  elif [[ -d "$runner_dir" ]]; then
    sudo rm -rf "$runner_dir"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] Would install worker ${worker_id} for ${repo}."
    ((SUCCESS+=1)); return 0
  fi

  sudo mkdir -p "$runner_dir"
  sudo chown "$RUNNER_USER:$RUNNER_USER" "$runner_dir"
  sudo chmod 750 "$runner_dir"
  sudo -u "$RUNNER_USER" tar xzf "$ARCHIVE" -C "$runner_dir"

  for required in run.sh config.sh; do
    [[ -f "${runner_dir}/${required}" ]] || { err "${repo}/worker-${worker_id}: missing ${required}"; ((FAILED+=1)); return 1; }
  done

  local policy_file="${SECURITY_DIR}/runners/${runner_name}.conf"
  { printf 'OWNER_ACTOR_ID=%q\n' "$OWNER_ACTOR_ID"; printf 'EXPECTED_REPOSITORY=%q\n' "${OWNER}/${repo}"; } | sudo tee "$policy_file" >/dev/null
  sudo chown root:root "$policy_file"; sudo chmod 0644 "$policy_file"
  printf 'ACTIONS_RUNNER_HOOK_JOB_STARTED=%s\n' "$OWNER_GATE" | sudo -u "$RUNNER_USER" tee "${runner_dir}/.env" >/dev/null

  local reg_json reg_token
  reg_json="$(api POST "https://api.github.com/repos/${OWNER}/${repo}/actions/runners/registration-token")" || { err "${repo}/worker-${worker_id}: registration token failed"; ((FAILED+=1)); return 1; }
  reg_token="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' <<<"$reg_json")"
  [[ -n "$reg_token" ]] || { err "${repo}/worker-${worker_id}: empty registration token"; ((FAILED+=1)); return 1; }

  (cd "$runner_dir" && sudo -u "$RUNNER_USER" ./config.sh \
    --unattended \
    --url "https://github.com/${OWNER}/${repo}" \
    --token "$reg_token" \
    --name "$runner_name" \
    --work "$WORK_DIR" \
    --labels "$CUSTOM_LABELS" \
    --replace) || { err "${repo}/worker-${worker_id}: config failed"; ((FAILED+=1)); return 1; }

  [[ -x "${runner_dir}/svc.sh" ]] || { err "${repo}/worker-${worker_id}: svc.sh was not created after config"; ((FAILED+=1)); return 1; }

  (cd "$runner_dir" && sudo ./svc.sh install "$RUNNER_USER" >/dev/null)
  (cd "$runner_dir" && sudo ./svc.sh start >/dev/null)
  sleep 1

  if (cd "$runner_dir" && sudo ./svc.sh status 2>&1) | grep -qiE 'active \(running\)|active: active|running'; then
    ok "${repo}/worker-${worker_id}: ACTIVE"
  else
    warn "${repo}/worker-${worker_id}: service installed but ACTIVE was not confirmed."
    (cd "$runner_dir" && sudo ./svc.sh status) || true
  fi
  ((SUCCESS+=1))
}

install_repo_runner() {
  local repo="$1" visibility="$2"
  local i
  for ((i=1; i<=WORKERS; i++)); do
    install_one_worker "$repo" "$visibility" "$i" || true
  done
}

while IFS=$'\t' read -r repo visibility branch; do install_repo_runner "$repo" "$visibility"; done < "$REPO_TSV"

echo
echo "============================================================"
echo " RESULT"
echo "============================================================"
echo "Success : $SUCCESS"
echo "Skipped : $SKIPPED"
echo "Failed  : $FAILED"
echo "Root    : $ROOT_DIR"
echo "Workers : $WORKERS per selected repository"
echo "Version : $RUNNER_VERSION"
echo "============================================================"

[[ "$FAILED" -eq 0 ]] || exit 2
ok "Runner fleet installation completed."
echo
echo "Useful checks:"
echo "  systemctl list-units --type=service | grep actions.runner"
echo "  find '$ROOT_DIR' -maxdepth 3 -name .runner -print"
echo
echo "Workflow selector compatible with the pool:"
echo "  runs-on: [self-hosted, linux, x64]"
echo "  or: [self-hosted, linux, x64, trusted, owner-gated, personal-fleet]"
