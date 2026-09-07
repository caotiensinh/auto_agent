#!/usr/bin/env bash
set -Eeuo pipefail
AUTO_AGENT_COMPONENT=openclaw-sso-v2

OPENCLAW_BACKEND_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_PUBLIC_PORT="${OPENCLAW_PUBLIC_PORT:-18790}"
PUBLIC_DOMAIN="${AUTO_AGENT_PUBLIC_DOMAIN:-kumakenchi.jp}"
OPENCLAW_PUBLIC_HOST="${AUTO_AGENT_OPENCLAW_PUBLIC_HOST:-openclaw.${PUBLIC_DOMAIN}}"

CFG_DIR="$HOME/.config/auto_agent"
ENV_FILE="$CFG_DIR/control.env"
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
NGINX_CONFIG="/etc/nginx/conf.d/auto-agent-control-center.conf"
ROTATE_CONTROL_SECRETS="${ROTATE_CONTROL_SECRETS:-0}"

log(){ printf '\033[1;34m[OPENCLAW-SSO-V2]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[OPENCLAW-SSO-V2:OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[OPENCLAW-SSO-V2:WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[OPENCLAW-SSO-V2:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

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

iface="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
cidr="$(ip -o -4 addr show dev "$iface" scope global | awk 'NR==1{print $4}')"
[[ -n "$cidr" ]] || die "Cannot detect laptop LAN IPv4"
LAPTOP_IP="${cidr%/*}"

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
  ok "Control secrets rotated; existing Auto Agent sessions invalidated"
fi

# shellcheck disable=SC1090
source "$ENV_FILE"
: "${AUTO_AGENT_PROXY_IDENTITY:?AUTO_AGENT_PROXY_IDENTITY missing}"
: "${OPENCLAW_LOCAL_PASSWORD:?OPENCLAW_LOCAL_PASSWORD missing}"

sudo grep -Fq 'X-Auto-Agent-SSO-Boundary 1' "$NGINX_CONFIG" || die "Signed public SSO callback boundary missing"
sudo grep -Fq 'proxy_set_header Cookie $http_cookie;' "$NGINX_CONFIG" || die "Native SSO bridge cookie forwarding missing"
sudo grep -Fq 'proxy_set_header X-Forwarded-For $auto_agent_client_ip;' "$NGINX_CONFIG" || die "Safe forwarded-client overwrite missing"
sudo grep -Fq 'proxy_set_header X-Forwarded-User' "$NGINX_CONFIG" || die "Trusted identity overwrite missing"
sudo grep -Fq "proxy_pass http://127.0.0.1:${OPENCLAW_BACKEND_PORT};" "$NGINX_CONFIG" || die "OpenClaw backend must remain loopback-only"
if sudo grep -Fqi 'Cf-Access-Jwt-Assertion' "$NGINX_CONFIG"; then
  die "Insecure Cloudflare-header authentication regression detected"
fi
ok "Nginx resilient SSO bridge + attribution boundary verified"

python3 - "$OPENCLAW_LOCAL_PASSWORD" "$LAPTOP_IP" "$OPENCLAW_PUBLIC_PORT" "$AUTO_AGENT_PROXY_IDENTITY" "$OPENCLAW_PUBLIC_HOST" <<'PY' | "$OPENCLAW" config patch --stdin >/dev/null
import json, sys
password, ip, port, identity, public_host = sys.argv[1:]
public_origin = f"https://{public_host}"
print(json.dumps({
    "gateway": {
        "mode": "local",
        "bind": "loopback",
        "trustedProxies": ["127.0.0.1"],
        "publicOrigin": public_origin,
        "auth": {
            "mode": "trusted-proxy",
            "token": None,
            "password": password,
            "identityScopes": {identity: ["operator.admin"]},
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
        },
        "controlUi": {
            "allowedOrigins": [f"http://{ip}:{port}", public_origin]
        },
        "http": {
            "endpoints": {
                "chatCompletions": {"enabled": True}
            }
        }
    }
}))
PY

"$OPENCLAW" config validate >/dev/null || die "OpenClaw v0.5.9 config validation failed"

python3 - "$OPENCLAW_CONFIG" "$AUTO_AGENT_PROXY_IDENTITY" "$LAPTOP_IP" "$OPENCLAW_PUBLIC_PORT" "$OPENCLAW_PUBLIC_HOST" <<'PY'
import json, pathlib, sys
path, identity, ip, port, public_host = sys.argv[1:]
d = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
g = d.get("gateway") or {}
a = g.get("auth") or {}
tp = a.get("trustedProxy") or {}
daa = tp.get("deviceAutoApprove") or {}
origins = set((g.get("controlUi") or {}).get("allowedOrigins") or [])
assert g.get("bind") == "loopback", "gateway must remain loopback-only"
assert g.get("trustedProxies") == ["127.0.0.1"], "only loopback nginx may be trusted"
assert g.get("publicOrigin") == f"https://{public_host}", "publicOrigin mismatch"
assert a.get("mode") == "trusted-proxy", "trusted-proxy auth required"
assert tp.get("allowLoopback") is True, "same-host proxy opt-in required"
assert tp.get("allowUsers") == [identity], "proxy identity allowlist mismatch"
assert set(tp.get("requiredHeaders") or []) == {"x-forwarded-proto", "x-forwarded-host"}
assert daa.get("enabled") is True, "device auto-approval not enabled"
scopes = set(daa.get("scopes") or [])
required = {"operator.read", "operator.write", "operator.approvals", "operator.questions"}
assert scopes == required, f"unexpected device auto-approve scopes: {sorted(scopes)}"
assert "operator.admin" not in scopes, "persistent browser admin auto-approval is forbidden"
assert "operator.admin" in set((a.get("identityScopes") or {}).get(identity, [])), "session admin identity grant missing"
assert f"http://{ip}:{port}" in origins, "LAN Control UI origin missing"
assert f"https://{public_host}" in origins, "public Control UI origin missing"
PY
ok "OpenClaw trusted-proxy/publicOrigin policy verified"

log "Restarting OpenClaw Gateway once after final atomic configuration..."
"$OPENCLAW" gateway restart --safe >/dev/null 2>&1 || "$OPENCLAW" gateway restart >/dev/null 2>&1 || die "OpenClaw gateway restart command failed"

ready=0
for _ in $(seq 1 40); do
  if curl -fsS --max-time 2 "http://127.0.0.1:${OPENCLAW_BACKEND_PORT}/startupz" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True and d.get("status") == "started"' 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]] || { "$OPENCLAW" gateway status || true; die "OpenClaw did not recover after final configuration"; }
ok "OpenClaw /startupz=started"

body="$(mktemp)"
http_code="$(curl -sS --max-time 10 -o "$body" -w '%{http_code}' -H 'X-Forwarded-For: 198.51.100.10' -H 'X-Real-IP: 198.51.100.10' -H "X-Forwarded-User: ${AUTO_AGENT_PROXY_IDENTITY}" -H 'X-Forwarded-Proto: https' -H "X-Forwarded-Host: ${OPENCLAW_PUBLIC_HOST}" -H "Origin: https://${OPENCLAW_PUBLIC_HOST}" "http://127.0.0.1:${OPENCLAW_BACKEND_PORT}/" || true)"
if [[ "$http_code" != 200 ]]; then
  warn "OpenClaw trusted-proxy smoke failed: HTTP ${http_code}"
  sed -n '1,40p' "$body" >&2 || true
  rm -f "$body"
  die "OpenClaw trusted-proxy HTTP path is not READY"
fi
rm -f "$body"
ok "OpenClaw trusted-proxy HTTP smoke PASS"

if [[ "$ROTATE_CONTROL_SECRETS" == 1 ]]; then
  systemctl --user restart auto-agent-control-center.service || die "Control Center restart failed after credential rotation"
fi

printf '\n============================================================\n'
printf 'AUTO_AGENT OPENCLAW SINGLE-LOGIN v0.5.9 READY\n'
printf 'Human login       : Cloudflare Access + Auto Agent Workspace login\n'
printf 'Native handoff    : temporary Secure bridge cookie + GET, replay-protected, 180s TTL\n'
printf 'Access challenge  : one automatic handoff retry after first native Cloudflare challenge\n'
printf 'Native cookie     : host-only Secure session, 15m TTL with Workspace renewal\n'
printf 'Forwarded client  : Nginx-overwritten LAN peer / Cloudflare client IP\n'
printf 'Gateway secrets   : server-side only; never injected into browser\n'
printf 'Proxy identity    : allowlisted + header-overwritten\n'
printf 'Browser pairing   : automatic after trusted-proxy authentication\n'
printf 'Persistent scopes : read/write/approvals/questions\n'
printf 'Admin scope       : session-only via identityScopes\n'
printf 'Gateway restart   : exactly once in finalization phase\n'
printf '============================================================\n'
