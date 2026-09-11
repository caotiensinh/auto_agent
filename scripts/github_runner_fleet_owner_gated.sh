#!/usr/bin/env bash
set -Eeuo pipefail

# GitHub Personal Account Multi-Repo Self-Hosted Runner Installer
# Default owner: caotiensinh
#
# Purpose:
# - Ask for ONE GitHub PAT.
# - Discover repositories owned by the personal account.
# - Create a short-lived registration token for each repository.
# - Install/reinstall one self-hosted runner service per repository.
# - Default: private, non-archived repositories only.
#
# Security:
# - PAT is read silently and never written to disk by this script.
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
# Usage:
#   bash github_runner_fleet.sh
#   bash github_runner_fleet.sh --include-public
#   bash github_runner_fleet.sh --owner caotiensinh
#   bash github_runner_fleet.sh --repo workspace
#   bash github_runner_fleet.sh --dry-run

OWNER="caotiensinh"
ROOT_DIR="/opt/github-runners"
SECURITY_DIR="/etc/github-runner-security"
RUNNER_USER="github-runner"
WORK_DIR="_work"
CUSTOM_LABELS="trusted,owner-gated,personal-fleet"
INCLUDE_PUBLIC=0
DRY_RUN=0
ONLY_REPO=""
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
  --include-public      Also install runners for public repositories (RISKY)
  --no-reinstall        Skip repositories that already have a configured runner
  --dry-run             Discover and show actions without changing the machine
  -h, --help            Show this help

Default behavior:
  - private repositories only unless --include-public is explicitly used
  - archived repos skipped
  - every runner is protected by a root-owned pre-job OWNER GATE
  - only the authenticated GitHub account numeric actor ID is admitted
  - repository identity must match the runner's root-owned allowlist entry
  - runner services use a dedicated non-login OS account with no intended sudo access
  - existing managed runner for a repo is safely stopped/unconfigured and rebuilt
  - unrelated runner directories outside ROOT_DIR are never touched
EOF
}

while (($#)); do
  case "$1" in
    --owner) OWNER="${2:?missing owner}"; shift 2 ;;
    --root) ROOT_DIR="${2:?missing root dir}"; shift 2 ;;
    --repo) ONLY_REPO="${2:?missing repo name}"; shift 2 ;;
    --include-public) INCLUDE_PUBLIC=1; shift ;;
    --no-reinstall) REINSTALL=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$(id -u)" -ne 0 ]] || die "Do not run this script directly as root. Run as your normal Linux user; the installer will use sudo for hardened system files."

for cmd in curl tar python3 uname hostname; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

command -v sudo >/dev/null 2>&1 || die "sudo is required."

case "$(uname -s)" in
  Linux) ;;
  *) die "This version supports Linux only." ;;
esac

case "$(uname -m)" in
  x86_64|amd64)
    RUNNER_ARCH="x64"
    ;;
  aarch64|arm64)
    RUNNER_ARCH="arm64"
    ;;
  *)
    die "Unsupported architecture: $(uname -m)"
    ;;
esac

sudo -v
sudo mkdir -p "$ROOT_DIR" "$SECURITY_DIR/runners"
sudo chmod 755 "$ROOT_DIR"
sudo chmod 755 "$SECURITY_DIR"
sudo chmod 755 "$SECURITY_DIR/runners"

if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  log "Creating dedicated OS account: $RUNNER_USER"
  sudo useradd --system --create-home --home-dir "/var/lib/${RUNNER_USER}" --shell /usr/sbin/nologin "$RUNNER_USER"
fi

# Defense-in-depth: the runner account should not have passwordless sudo.
if sudo -u "$RUNNER_USER" sudo -n true >/dev/null 2>&1; then
  die "SECURITY BLOCK: '$RUNNER_USER' currently has passwordless sudo. Remove that privilege before installing self-hosted runners."
fi

printf '\n'
echo "============================================================"
echo " GitHub Self-Hosted Runner Fleet Installer"
echo "============================================================"
echo "Owner             : $OWNER"
echo "Root              : $ROOT_DIR"
echo "Architecture      : $RUNNER_ARCH"
echo "Runner OS account : $RUNNER_USER (non-login, no intended sudo)"
echo "Security gate     : root-owned pre-job actor/repository admission"
echo "Repository policy : $([[ "$INCLUDE_PUBLIC" -eq 1 ]] && echo 'private + PUBLIC' || echo 'PRIVATE ONLY')"
echo "Reinstall         : $([[ "$REINSTALL" -eq 1 ]] && echo yes || echo no)"
echo "Dry-run           : $([[ "$DRY_RUN" -eq 1 ]] && echo yes || echo no)"
echo "============================================================"
printf '\n'

if [[ "$INCLUDE_PUBLIC" -eq 1 ]]; then
  warn "PUBLIC repositories are enabled."
  warn "A malicious or compromised workflow/PR can execute code on this runner host."
  read -r -p "Type I_ACCEPT_PUBLIC_RUNNER_RISK to continue: " ACK
  [[ "$ACK" == "I_ACCEPT_PUBLIC_RUNNER_RISK" ]] || die "Public repository installation cancelled."
fi

echo "Paste a GitHub PAT with access to the repositories."
echo "The token will NOT be echoed and is not intentionally written to disk."
read -r -s -p "GitHub PAT: " GH_PAT
echo
[[ -n "$GH_PAT" ]] || die "Empty token."

cleanup() {
  unset GH_PAT || true
}
trap cleanup EXIT

api() {
  local method="$1"
  local url="$2"
  shift 2
  curl -fsS -X "$method" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@" \
    "$url"
}

log "Validating token..."
USER_JSON="$(api GET "https://api.github.com/user")" || die "GitHub authentication failed."
LOGIN="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("login",""))' <<<"$USER_JSON")"
[[ -n "$LOGIN" ]] || die "Could not determine authenticated GitHub login."
ok "Authenticated as: $LOGIN"
OWNER_ACTOR_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$USER_JSON")"
[[ "$OWNER_ACTOR_ID" =~ ^[0-9]+$ ]] || die "Could not determine authenticated GitHub numeric user ID."
ok "Owner actor ID: $OWNER_ACTOR_ID"

if [[ "$LOGIN" != "$OWNER" ]]; then
  warn "Authenticated account is '$LOGIN', but requested owner is '$OWNER'."
  read -r -p "Continue anyway? [y/N]: " ans
  [[ "${ans,,}" == "y" ]] || die "Cancelled."
fi

# Install a root-owned admission gate outside every runner application directory.
# GitHub executes ACTIONS_RUNNER_HOOK_JOB_STARTED after assignment but before
# workflow steps. A non-zero exit code blocks the job fail-closed.
OWNER_GATE="${SECURITY_DIR}/owner_gate.sh"
if [[ "$DRY_RUN" -eq 0 ]]; then
  TMP_GATE="$(mktemp)"
  cat > "$TMP_GATE" <<'OWNER_GATE_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

deny() {
  printf '[OWNER-GATE] DENY: %s\n' "$*" >&2
  exit 97
}

allow() {
  printf '[OWNER-GATE] ALLOW: actor_id=%s repository=%s event=%s runner=%s\n' \
    "${GITHUB_ACTOR_ID:-?}" "${GITHUB_REPOSITORY:-?}" "${GITHUB_EVENT_NAME:-?}" "${RUNNER_NAME:-?}"
  exit 0
}

[[ "${GITHUB_ACTIONS:-}" == "true" ]] || deny "not a GitHub Actions job"
[[ "${RUNNER_ENVIRONMENT:-}" == "self-hosted" ]] || deny "runner environment is not self-hosted"

runner_name="${RUNNER_NAME:-}"
[[ -n "$runner_name" ]] || deny "RUNNER_NAME missing"
safe_runner_name="${runner_name//[^A-Za-z0-9._-]/-}"

conf="/etc/github-runner-security/runners/${safe_runner_name}.conf"
[[ -r "$conf" ]] || deny "root-owned runner policy missing"

# shellcheck disable=SC1090
source "$conf"

[[ "${OWNER_ACTOR_ID:-}" =~ ^[0-9]+$ ]] || deny "invalid OWNER_ACTOR_ID policy"
[[ -n "${EXPECTED_REPOSITORY:-}" ]] || deny "EXPECTED_REPOSITORY policy missing"

[[ "${GITHUB_ACTOR_ID:-}" == "$OWNER_ACTOR_ID" ]] || \
  deny "actor '${GITHUB_ACTOR:-unknown}' (${GITHUB_ACTOR_ID:-missing}) is not the authorized owner"

[[ "${GITHUB_REPOSITORY:-}" == "$EXPECTED_REPOSITORY" ]] || \
  deny "repository '${GITHUB_REPOSITORY:-missing}' is not '${EXPECTED_REPOSITORY}'"

# Explicitly reject common bot identities even if a future platform anomaly
# presented an unexpected actor mapping.
case "${GITHUB_ACTOR:-}" in
  dependabot\[bot\]|github-actions\[bot\]|renovate\[bot\])
    deny "bot actor is not permitted"
    ;;
esac

allow
OWNER_GATE_EOF

  sudo install -o root -g root -m 0755 "$TMP_GATE" "$OWNER_GATE"
  rm -f "$TMP_GATE"
  ok "Installed root-owned owner gate: $OWNER_GATE"
fi

log "Resolving latest GitHub Actions runner release..."
RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/actions/runner/releases/latest")"
RUNNER_VERSION="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))' <<<"$RELEASE_JSON")"
[[ -n "$RUNNER_VERSION" ]] || die "Could not determine latest runner version."

ASSET="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${ASSET}"
CACHE_DIR="${ROOT_DIR}/.cache"
ARCHIVE="${CACHE_DIR}/${ASSET}"

sudo mkdir -p "$CACHE_DIR"
sudo chmod 755 "$CACHE_DIR"

if ! sudo test -s "$ARCHIVE"; then
  log "Downloading runner v${RUNNER_VERSION} (${RUNNER_ARCH})..."
  if [[ "$DRY_RUN" -eq 0 ]]; then
    TMP_ARCHIVE="$(mktemp)"
    curl -fL --retry 3 --retry-delay 2 -o "$TMP_ARCHIVE" "$DOWNLOAD_URL"
    sudo mv "$TMP_ARCHIVE" "$ARCHIVE"
    sudo chown root:root "$ARCHIVE"
    sudo chmod 644 "$ARCHIVE"
  fi
else
  ok "Using cached runner archive: $ARCHIVE"
fi

log "Discovering repositories owned by ${OWNER}..."
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
owner = sys.argv[1]
include_public = sys.argv[2] == "1"
only_repo = sys.argv[3]
json_path = sys.argv[4]

with open(json_path, "r", encoding="utf-8") as f:
    repos = json.load(f)

for r in repos:
    if r.get("owner", {}).get("login") != owner:
        continue
    if r.get("archived"):
        continue
    if only_repo and r.get("name") != only_repo:
        continue
    if not include_public and not r.get("private", False):
        continue
    print("\t".join([
        r.get("name", ""),
        "private" if r.get("private", False) else "public",
        r.get("default_branch") or "",
    ]))
PY

  rm -f "$PAGE_JSON"
  ((page++))
done

if [[ ! -s "$REPO_TSV" ]]; then
  die "No matching repositories found. Check token access, owner, and filters."
fi

TOTAL="$(wc -l < "$REPO_TSV" | tr -d ' ')"
log "Repositories selected: $TOTAL"
cat "$REPO_TSV" | while IFS=$'\t' read -r repo visibility branch; do
  printf '  - %-40s %-8s default=%s\n' "$repo" "$visibility" "$branch"
done

printf '\n'
if [[ "$DRY_RUN" -eq 0 ]]; then
  read -r -p "Proceed with runner installation/reinstallation for these repositories? [y/N]: " PROCEED
  [[ "${PROCEED,,}" == "y" ]] || die "Cancelled."
fi

HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
SUCCESS=0
FAILED=0
SKIPPED=0

install_repo_runner() {
  local repo="$1"
  local visibility="$2"
  local runner_dir="${ROOT_DIR}/${repo}"
  local runner_name="${HOST_SHORT}-${repo}"
  runner_name="${runner_name//[^A-Za-z0-9._-]/-}"
  runner_name="${runner_name:0:63}"

  echo
  echo "------------------------------------------------------------"
  log "Repository: ${OWNER}/${repo} (${visibility})"
  log "Runner name: ${runner_name}"
  log "Directory: ${runner_dir}"

  if [[ -f "${runner_dir}/.runner" ]]; then
    if [[ "$REINSTALL" -eq 0 ]]; then
      warn "Existing runner detected; skipping due to --no-reinstall."
      ((SKIPPED+=1))
      return 0
    fi

    log "Existing managed runner detected. Stopping old service..."
    if [[ "$DRY_RUN" -eq 0 ]]; then
      if [[ -x "${runner_dir}/svc.sh" ]]; then
        (cd "$runner_dir" && sudo ./svc.sh stop >/dev/null 2>&1) || true
        (cd "$runner_dir" && sudo ./svc.sh uninstall >/dev/null 2>&1) || true
      fi

      # Obtain a fresh removal token via the repository API.
      local remove_json remove_token
      remove_json="$(api POST "https://api.github.com/repos/${OWNER}/${repo}/actions/runners/remove-token")" || {
        err "Could not create removal token for ${repo}."
        ((FAILED+=1))
        return 1
      }
      remove_token="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' <<<"$remove_json")"

      if [[ -x "${runner_dir}/config.sh" && -n "$remove_token" ]]; then
        (
          cd "$runner_dir"
          sudo -u "$RUNNER_USER" ./config.sh remove --token "$remove_token" >/dev/null 2>&1 || true
        )
      fi

      # Preserve a local backup of diagnostic metadata only.
      if [[ -f "${runner_dir}/.runner" ]]; then
        cp -a "${runner_dir}/.runner" "${runner_dir}/.runner.previous.$(date +%Y%m%d%H%M%S)" || true
      fi
      sudo rm -rf "$runner_dir"
      sudo rm -f "${SECURITY_DIR}/runners/${runner_name}.conf"
    else
      log "[dry-run] Would stop, unregister, and rebuild existing runner."
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] Would request repository registration token."
    log "[dry-run] Would install runner v${RUNNER_VERSION} and systemd service."
    ((SUCCESS+=1))
    return 0
  fi

  sudo mkdir -p "$runner_dir"
  sudo chown "$RUNNER_USER:$RUNNER_USER" "$runner_dir"
  sudo chmod 750 "$runner_dir"

  sudo -u "$RUNNER_USER" tar xzf "$ARCHIVE" -C "$runner_dir"

  for required in run.sh config.sh svc.sh; do
    if [[ ! -f "${runner_dir}/${required}" ]]; then
      err "${repo}: runner install is incomplete; missing ${required}"
      ((FAILED+=1))
      return 1
    fi
  done

  # Root-owned policy cannot be changed by the workflow service account.
  local policy_file="${SECURITY_DIR}/runners/${runner_name}.conf"
  {
    printf 'OWNER_ACTOR_ID=%q\n' "$OWNER_ACTOR_ID"
    printf 'EXPECTED_REPOSITORY=%q\n' "${OWNER}/${repo}"
  } | sudo tee "$policy_file" >/dev/null
  sudo chown root:root "$policy_file"
  sudo chmod 0644 "$policy_file"

  # Tell the GitHub runner to invoke the root-owned gate before every job.
  printf 'ACTIONS_RUNNER_HOOK_JOB_STARTED=%s\n' "$OWNER_GATE" | \
    sudo -u "$RUNNER_USER" tee "${runner_dir}/.env" >/dev/null

  local reg_json reg_token
  reg_json="$(api POST "https://api.github.com/repos/${OWNER}/${repo}/actions/runners/registration-token")" || {
    err "Unable to create registration token for ${OWNER}/${repo}."
    err "Token likely lacks repository Administration write permission."
    [[ "$KEEP_FAILED_DIR" -eq 1 ]] || sudo rm -rf "$runner_dir"
    ((FAILED+=1))
    return 1
  }

  reg_token="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' <<<"$reg_json")"
  [[ -n "$reg_token" ]] || {
    err "Registration token response was empty for ${repo}."
    ((FAILED+=1))
    return 1
  }

  log "Configuring runner..."
  (
    cd "$runner_dir"
    sudo -u "$RUNNER_USER" ./config.sh \
      --unattended \
      --url "https://github.com/${OWNER}/${repo}" \
      --token "$reg_token" \
      --name "$runner_name" \
      --work "$WORK_DIR" \
      --labels "$CUSTOM_LABELS" \
      --replace
  ) || {
    err "Runner configuration failed for ${repo}."
    ((FAILED+=1))
    return 1
  }

  log "Installing systemd service..."
  (cd "$runner_dir" && sudo ./svc.sh install "$RUNNER_USER" >/dev/null)
  (cd "$runner_dir" && sudo ./svc.sh start >/dev/null)

  sleep 2

  if (cd "$runner_dir" && sudo ./svc.sh status 2>&1) | grep -qiE 'active \(running\)|active: active|running'; then
    ok "${repo}: service active."
  else
    warn "${repo}: service installed but active status was not confirmed."
    (cd "$runner_dir" && sudo ./svc.sh status) || true
  fi

  ((SUCCESS+=1))
}

while IFS=$'\t' read -r repo visibility branch; do
  install_repo_runner "$repo" "$visibility" || true
done < "$REPO_TSV"

echo
echo "============================================================"
echo " RESULT"
echo "============================================================"
echo "Success : $SUCCESS"
echo "Skipped : $SKIPPED"
echo "Failed  : $FAILED"
echo "Root    : $ROOT_DIR"
echo "Version : $RUNNER_VERSION"
echo "============================================================"

if [[ "$FAILED" -gt 0 ]]; then
  warn "Some repositories failed. Review the errors above."
  warn "Common cause: PAT does not have Administration write permission for those repositories."
  exit 2
fi

ok "Runner fleet installation completed."
echo
echo "Useful checks:"
echo "  systemctl list-units --type=service | grep actions.runner"
echo "  find '$ROOT_DIR' -maxdepth 2 -name .runner -print"
echo
echo "Workflow selector compatible with every installed Linux x64 runner:"
echo "  runs-on: [self-hosted, linux, x64]"
echo
echo "Optional stricter selector for this fleet:"
echo "  runs-on: [self-hosted, linux, x64, trusted, owner-gated, personal-fleet]"
echo
echo "OWNER-GATE security properties:"
echo "  - only GitHub actor ID: $OWNER_ACTOR_ID ($LOGIN)"
echo "  - exact repository match per runner"
echo "  - gate executes before workflow steps"
echo "  - policy + hook are root-owned"
echo "  - runner service account: $RUNNER_USER"
echo "  - bot actors denied"
