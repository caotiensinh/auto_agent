#!/usr/bin/env bash
set -Eeuo pipefail
AUTO_AGENT_COMPONENT=openclaw-sso

OPENCLAW_BACKEND_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
CFG_DIR="$HOME/.config/auto_agent"
ENV_FILE="$CFG_DIR/control.env"
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
NGINX_CONFIG="/etc/nginx/conf.d/auto-agent-control-center.conf"
ROTATE_CONTROL_SECRETS="${ROTATE_CONTROL_SECRETS:-0}"

log(){ printf '\033[1;34m[OPENCLAW-SSO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[OPENCLAW-SSO:OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[OPENCLAW-SSO:WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[OPENCLAW-SSO:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run as normal Ubuntu user"
[[ -r "$ENV_FILE" ]] || die "Control Center credential file missing: $ENV_FILE"
command -v sudo >/dev/null 2>&1 || die "sudo required"
sudo test -f "$NGINX_CONFIG" || die "Unified Nginx config missing: $NGINX_CONFIG"
command -v python3 >/dev/null 2>&1 || die "python3 required"
command -v openssl >/dev/null 2>&1 || die "openssl required"

PATH="$HOME/.local/bin:$HOME/.hermes/bin:$HOME/.hermes/node/bin:$HOME/.openclaw/bin:$PATH"
export PATH
if ! command -v node >/dev/null 2>&1; then
  n="$(find "$HOME/.hermes" "$HOME/.local" -maxdepth 5 -type f -name node -perm -u+x -print -quit 2>/dev/null || true)"
  [[ -n "$n" ]] && PATH="$(dirname "$n"):$PATH" && export PATH
fi
OPENCLAW="$(command -v openclaw || true)"
[[ -x "$OPENCLAW" ]] || die "OpenClaw executable not found"

replace_env_value(){
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  python3 - "$ENV_FILE" "$tmp" "$key" "$value" <<'PY'
import pathlib, sys
src, dst, key, value = sys.argv[1:]
p = pathlib.Path(src)
lines = p.read_text(encoding="utf-8").splitlines()
out = []
seen = False
for line in lines:
    if line.startswith(key + "="):
        out.append(f"{key}={value}")
        seen = True
    else:
        out.append(line)
if not seen:
    out.append(f"{key}={value}")
pathlib.Path(dst).write_text("\n".join(out) + "\n", encoding="utf-8")
PY
  install -m 600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"
}

if [[ "$ROTATE_CONTROL_SECRETS" == 1 ]]; then
  log "Rotating Control Center secrets because ROTATE_CONTROL_SECRETS=1..."
  replace_env_value AUTO_AGENT_CONTROL_PASSWORD "$(openssl rand -base64 24 | tr -d '\n')"
  replace_env_value AUTO_AGENT_SESSION_SECRET "$(openssl rand -hex 32)"
  replace_env_value OPENCLAW_LOCAL_PASSWORD "$(openssl rand -base64 24 | tr -d '\n')"
  ok "Control secrets rotated; existing browser sessions are intentionally invalidated"
fi

# shellcheck disable=SC1090
source "$ENV_FILE"
: "${AUTO_AGENT_PROXY_IDENTITY:?AUTO_AGENT_PROXY_IDENTITY missing}"
: "${OPENCLAW_LOCAL_PASSWORD:?OPENCLAW_LOCAL_PASSWORD missing}"

# The browser never receives OpenClaw's password/token. The outer Control Center
# session is the only human login. Nginx converts that authenticated session into
# one fixed trusted-proxy identity. New browser device enrollment is then approved
# automatically only after trusted-proxy authentication.
#
# IMPORTANT: persistent device grants intentionally exclude operator.admin.
# Full admin is granted connection-only through identityScopes for the single
# allowlisted proxy identity, matching OpenClaw's recommended security model.
python3 - "$OPENCLAW_LOCAL_PASSWORD" "$AUTO_AGENT_PROXY_IDENTITY" <<'PY' \
  | "$OPENCLAW" config patch --stdin >/dev/null
import json, sys
password, identity = sys.argv[1:]
print(json.dumps({
    "gateway": {
        "mode": "local",
        "bind": "loopback",
        "trustedProxies": ["127.0.0.1"],
        "auth": {
            "mode": "trusted-proxy",
            "token": None,
            "password": password,
            "identityScopes": {
                identity: ["operator.admin"]
            },
            "trustedProxy": {
                "userHeader": "x-forwarded-user",
                "requiredHeaders": ["x-forwarded-proto", "x-forwarded-host"],
                "allowLoopback": True,
                "allowUsers": [identity],
                "deviceAutoApprove": {
                    "enabled": True,
                    "scopes": [
                        "operator.read",
                        "operator.write",
                        "operator.approvals",
                        "operator.questions"
                    ]
                }
            }
        }
    }
}))
PY

"$OPENCLAW" config validate >/dev/null || die "OpenClaw SSO config validation failed"

python3 - "$OPENCLAW_CONFIG" "$AUTO_AGENT_PROXY_IDENTITY" <<'PY'
import json, pathlib, sys
path, identity = sys.argv[1:]
d = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
g = d.get("gateway") or {}
a = g.get("auth") or {}
tp = a.get("trustedProxy") or {}
daa = tp.get("deviceAutoApprove") or {}
assert g.get("bind") == "loopback", "gateway must remain loopback-only"
assert g.get("trustedProxies") == ["127.0.0.1"], "only loopback proxy may be trusted"
assert a.get("mode") == "trusted-proxy", "trusted-proxy auth required"
assert tp.get("allowLoopback") is True, "same-host proxy opt-in required"
assert tp.get("allowUsers") == [identity], "proxy identity allowlist mismatch"
assert daa.get("enabled") is True, "device auto-approval not enabled"
scopes = set(daa.get("scopes") or [])
required = {"operator.read", "operator.write", "operator.approvals", "operator.questions"}
assert scopes == required, f"unexpected device auto-approve scopes: {sorted(scopes)}"
assert "operator.admin" not in scopes, "persistent browser admin auto-approval is forbidden"
assert "operator.admin" in set((a.get("identityScopes") or {}).get(identity, [])), "session admin identity grant missing"
PY
ok "OpenClaw trusted-proxy SSO policy verified"

# The Nginx config is intentionally root-owned mode 0600. Inspect it through
# sudo rather than weakening its permissions just so the unprivileged installer
# process can read it.
sudo grep -Fq 'auth_request /_auth' "$NGINX_CONFIG" || die "Nginx session auth_request missing"
sudo grep -Fq 'proxy_set_header X-Forwarded-User' "$NGINX_CONFIG" || die "Nginx trusted identity header overwrite missing"
sudo grep -Fq 'proxy_set_header X-Forwarded-For $remote_addr;' "$NGINX_CONFIG" || die "Nginx client-address overwrite missing"
sudo grep -Fq "proxy_pass http://127.0.0.1:${OPENCLAW_BACKEND_PORT};" "$NGINX_CONFIG" || die "OpenClaw backend must remain loopback-only"
ok "Nginx authenticated identity boundary verified"

"$OPENCLAW" gateway restart --safe >/dev/null 2>&1 || "$OPENCLAW" gateway restart >/dev/null 2>&1 || true

ready=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 "http://127.0.0.1:${OPENCLAW_BACKEND_PORT}/startupz" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True and d.get("status") == "started"' 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]] || { "$OPENCLAW" gateway status || true; die "OpenClaw did not recover after SSO configuration"; }

if [[ "$ROTATE_CONTROL_SECRETS" == 1 ]]; then
  systemctl --user restart auto-agent-control-center.service \
    || die "Control Center restart failed after credential rotation"
fi

printf '\n============================================================\n'
printf 'AUTO_AGENT OPENCLAW SINGLE-LOGIN READY\n'
printf 'Human login       : Auto Agent Control Center only\n'
printf 'Gateway secrets   : server-side only; never injected into browser\n'
printf 'Proxy identity    : allowlisted + header-overwritten\n'
printf 'Browser pairing   : automatic after trusted-proxy authentication\n'
printf 'Persistent scopes : read/write/approvals/questions\n'
printf 'Admin scope       : session-only via identityScopes\n'
printf '============================================================\n'
