#!/usr/bin/env bash
set -Eeuo pipefail
AUTO_AGENT_COMPONENT=unified-control-v2

CENTER_PORT="${CONTROL_CENTER_PORT:-8088}"
CENTER_INTERNAL_PORT="${CONTROL_CENTER_INTERNAL_PORT:-18088}"
CENTER_API_TIMEOUT="${CONTROL_CENTER_API_TIMEOUT:-930}"
HERMES_BACKEND_PORT="${HERMES_DASHBOARD_PORT:-9119}"
OPENCLAW_BACKEND_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
HERMES_PUBLIC_PORT="${HERMES_PUBLIC_PORT:-9120}"
OPENCLAW_PUBLIC_PORT="${OPENCLAW_PUBLIC_PORT:-18790}"

PUBLIC_DOMAIN="${AUTO_AGENT_PUBLIC_DOMAIN:-kumakenchi.jp}"
CENTER_PUBLIC_HOST="${AUTO_AGENT_CENTER_PUBLIC_HOST:-workspace.${PUBLIC_DOMAIN}}"
HERMES_PUBLIC_HOST="${AUTO_AGENT_HERMES_PUBLIC_HOST:-hermes.${PUBLIC_DOMAIN}}"
OPENCLAW_PUBLIC_HOST="${AUTO_AGENT_OPENCLAW_PUBLIC_HOST:-openclaw.${PUBLIC_DOMAIN}}"

REPO_RAW="${AUTO_AGENT_REPO_RAW:-https://raw.githubusercontent.com/caotiensinh/auto_agent/main}"
CFG_DIR="$HOME/.config/auto_agent"
ENV_FILE="$CFG_DIR/control.env"
APP_DIR="$HOME/.local/share/auto_agent"
APP_FILE="$APP_DIR/control_center_v2.py"
UNIT="auto-agent-control-center.service"

log(){ printf '\033[1;34m[UNIFIED-V2]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[UNIFIED-V2:OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[UNIFIED-V2:WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[UNIFIED-V2:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run as normal Ubuntu user"
command -v sudo >/dev/null || die "sudo required"
[[ "$CENTER_API_TIMEOUT" =~ ^[0-9]+$ ]] || die "CONTROL_CENTER_API_TIMEOUT must be an integer"
(( CENTER_API_TIMEOUT >= 60 && CENTER_API_TIMEOUT <= 3600 )) || die "CONTROL_CENTER_API_TIMEOUT must be between 60 and 3600 seconds"

python3 - "$PUBLIC_DOMAIN" "$CENTER_PUBLIC_HOST" "$HERMES_PUBLIC_HOST" "$OPENCLAW_PUBLIC_HOST" <<'PY'
import re,sys
public_domain = sys.argv[1].strip().lower().lstrip('.')
pat = re.compile(r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$")
if not pat.fullmatch(public_domain):
    raise SystemExit(f"invalid public domain: {public_domain!r}")
for host in sys.argv[2:]:
    if not pat.fullmatch(host):
        raise SystemExit(f"invalid public hostname: {host!r}")
    if not host.lower().endswith('.' + public_domain) and host.lower() != public_domain:
        raise SystemExit(f"public hostname outside configured domain: {host!r}")
PY

PATH="$HOME/.local/bin:$HOME/.hermes/bin:$HOME/.hermes/node/bin:$HOME/.openclaw/bin:$PATH"
export PATH
if ! command -v node >/dev/null 2>&1; then
  n="$(find "$HOME/.hermes" "$HOME/.local" -maxdepth 5 -type f -name node -perm -u+x -print -quit 2>/dev/null || true)"
  [[ -n "$n" ]] && PATH="$(dirname "$n"):$PATH" && export PATH
fi

HERMES="$(command -v hermes || true)"
OPENCLAW="$(command -v openclaw || true)"
[[ -x "$HERMES" ]] || die "Hermes not found"
[[ -x "$OPENCLAW" ]] || die "OpenClaw not found"

pkg(){ dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }
missing=()
for p in nginx openssl; do pkg "$p" || missing+=("$p"); done
if ((${#missing[@]})); then
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
else
  ok "nginx/openssl already installed; reuse"
fi
sudo nginx -V 2>&1 | grep -q -- '--with-http_sub_module' || die "Ubuntu nginx lacks http_sub_module required for native navigation"

iface="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
cidr="$(ip -o -4 addr show dev "$iface" scope global | awk 'NR==1{print $4}')"
[[ -n "$cidr" ]] || die "Cannot detect laptop LAN IPv4"
LAPTOP_IP="${cidr%/*}"
LAN_CIDR="$(python3 - "$cidr" <<'PY'
import ipaddress,sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"
ok "LAN: $iface / $LAPTOP_IP / $LAN_CIDR"
ok "Public routes: $CENTER_PUBLIC_HOST / $HERMES_PUBLIC_HOST / $OPENCLAW_PUBLIC_HOST"

mkdir -p "$CFG_DIR" "$APP_DIR"
chmod 700 "$CFG_DIR" "$APP_DIR"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

add_secret(){
  local key="$1" value="$2"
  grep -q "^${key}=" "$ENV_FILE" || printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
}
add_secret AUTO_AGENT_CONTROL_USERNAME admin
add_secret AUTO_AGENT_CONTROL_PASSWORD "$(openssl rand -base64 24 | tr -d '\n')"
add_secret AUTO_AGENT_SESSION_SECRET "$(openssl rand -hex 32)"
add_secret AUTO_AGENT_PROXY_IDENTITY auto-agent-admin
add_secret OPENCLAW_LOCAL_PASSWORD "$(openssl rand -base64 24 | tr -d '\n')"

# shellcheck disable=SC1090
source "$ENV_FILE"
ok "Single-login credentials ready; existing values reused"

tmp="$(mktemp)"
bust="$(date +%s%N 2>/dev/null || date +%s)"
curl -fsSL --proto '=https' --tlsv1.2 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "${REPO_RAW}/scripts/control_center_v2.py?auto_agent_cache_bust=${bust}" -o "$tmp"
python3 -m py_compile "$tmp" || die "control_center_v2.py syntax invalid"
if ! cmp -s "$tmp" "$APP_FILE" 2>/dev/null; then
  install -m 700 "$tmp" "$APP_FILE"
  ok "Control Center auth logic installed/updated"
else
  ok "Control Center auth logic already current; reuse"
fi
rm -f "$tmp"

systemctl --user is-active --quiet auto-agent-hermes-dashboard.service || systemctl --user start auto-agent-hermes-dashboard.service || die "Hermes dashboard service not running"

mkdir -p "$HOME/.config/systemd/user"
unit_path="$HOME/.config/systemd/user/$UNIT"
cat >"$unit_path" <<EOF2
[Unit]
Description=auto_agent Unified Control Center v0.5.9
After=network-online.target auto-agent-hermes-dashboard.service
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=$HOME
Environment=PATH=$PATH
EnvironmentFile=$ENV_FILE
Environment=AUTO_AGENT_CENTER_HOST=127.0.0.1
Environment=AUTO_AGENT_CENTER_PORT=$CENTER_INTERNAL_PORT
Environment=AUTO_AGENT_PUBLIC_DOMAIN=$PUBLIC_DOMAIN
Environment=AUTO_AGENT_HERMES_PUBLIC_PORT=$HERMES_PUBLIC_PORT
Environment=AUTO_AGENT_OPENCLAW_PUBLIC_PORT=$OPENCLAW_PUBLIC_PORT
Environment=AUTO_AGENT_CENTER_PUBLIC_HOST=$CENTER_PUBLIC_HOST
Environment=AUTO_AGENT_HERMES_PUBLIC_HOST=$HERMES_PUBLIC_HOST
Environment=AUTO_AGENT_OPENCLAW_PUBLIC_HOST=$OPENCLAW_PUBLIC_HOST
Environment=AUTO_AGENT_HERMES_BIN=$HERMES
Environment=AUTO_AGENT_OPENCLAW_BIN=$OPENCLAW
Environment=AUTO_AGENT_OPENCLAW_URL=http://127.0.0.1:$OPENCLAW_BACKEND_PORT
Environment=AUTO_AGENT_NATIVE_SESSION_TTL=900
Environment=AUTO_AGENT_SSO_TTL=180
ExecStart=/usr/bin/python3 $APP_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF2
chmod 600 "$unit_path"
systemctl --user daemon-reload
systemctl --user enable "$UNIT" >/dev/null
systemctl --user restart "$UNIT" || die "Control Center service restart failed"

backend_ok=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 "http://127.0.0.1:${CENTER_INTERNAL_PORT}/login" >/dev/null 2>&1; then
    backend_ok=1
    break
  fi
  sleep 1
done
if [[ "$backend_ok" != 1 ]]; then
  warn "Control Center backend did not pass /login health"
  systemctl --user status "$UNIT" --no-pager || true
  journalctl --user -u "$UNIT" -n 80 --no-pager || true
  die "Control Center backend failed"
fi
ok "Control Center backend reachable on 127.0.0.1:${CENTER_INTERNAL_PORT}"

# v0.5.9 SSO design:
# 1) the authenticated Workspace issues a signed, target-bound one-time token;
# 2) the token is carried in a short-lived HttpOnly Secure cookie limited to
#    Domain=.PUBLIC_DOMAIN and Path=/_auto_agent_sso;
# 3) the browser follows a GET to the native host. If Cloudflare Access inserts
#    an IdP/OTP redirect, the browser can still resume the same GET afterwards;
# 4) the native callback consumes the one-time token, clears the bridge cookie,
#    and creates a host-only native session. A single automatic retry handles a
#    first-visit Access challenge without creating an authentication loop.
# No Cf-Access-* header is accepted as an Auto Agent login boundary.
#
# OpenClaw trusted-proxy separately requires a non-loopback attributed client.
# Public routes overwrite X-Forwarded-For/Real-IP with Cf-Connecting-IP; LAN
# routes overwrite them with the socket peer. Client forwarded headers are never
# passed through.
NAV='<div id="auto-agent-nav" style="position:fixed;top:8px;right:8px;z-index:2147483647;background:#111827;color:#fff;padding:8px 10px;border-radius:9px;font:13px sans-serif;box-shadow:0 4px 18px #0008"><a style="color:#fff;text-decoration:none;margin-right:10px" href="$auto_agent_center_nav_url">Auto Agent</a><a style="color:#fff;text-decoration:none;margin-right:10px" href="$auto_agent_hermes_nav_url">Hermes</a><a style="color:#fff;text-decoration:none" href="$auto_agent_openclaw_nav_url">OpenClaw</a></div>'

nginx_tmp="$(mktemp)"
cat >"$nginx_tmp" <<EOF2
# Managed by caotiensinh/auto_agent v0.5.9
map \$http_upgrade \$auto_agent_upgrade { default upgrade; '' close; }

map \$http_cf_connecting_ip \$auto_agent_cf_client_ip {
  default \$http_cf_connecting_ip;
  "" \$remote_addr;
}

map "\$remote_addr|\$host" \$auto_agent_client_ip {
  default \$remote_addr;
  "127.0.0.1|${CENTER_PUBLIC_HOST}" \$auto_agent_cf_client_ip;
  "127.0.0.1|${HERMES_PUBLIC_HOST}" \$auto_agent_cf_client_ip;
  "127.0.0.1|${OPENCLAW_PUBLIC_HOST}" \$auto_agent_cf_client_ip;
}

map \$host \$auto_agent_client_scheme {
  default \$scheme;
  ${CENTER_PUBLIC_HOST} https;
  ${HERMES_PUBLIC_HOST} https;
  ${OPENCLAW_PUBLIC_HOST} https;
}

map \$host \$auto_agent_login_url {
  default "http://${LAPTOP_IP}:${CENTER_PORT}/login";
  ${HERMES_PUBLIC_HOST} "https://${CENTER_PUBLIC_HOST}/login?next=/sso/hermes";
  ${OPENCLAW_PUBLIC_HOST} "https://${CENTER_PUBLIC_HOST}/login?next=/sso/openclaw";
}

map \$host \$auto_agent_center_nav_url {
  default "http://${LAPTOP_IP}:${CENTER_PORT}/";
  ${HERMES_PUBLIC_HOST} "https://${CENTER_PUBLIC_HOST}/";
  ${OPENCLAW_PUBLIC_HOST} "https://${CENTER_PUBLIC_HOST}/";
}

map \$host \$auto_agent_hermes_nav_url {
  default "http://${LAPTOP_IP}:${HERMES_PUBLIC_PORT}/";
  ${HERMES_PUBLIC_HOST} "https://${CENTER_PUBLIC_HOST}/sso/hermes";
  ${OPENCLAW_PUBLIC_HOST} "https://${CENTER_PUBLIC_HOST}/sso/hermes";
}

map \$host \$auto_agent_openclaw_nav_url {
  default "http://${LAPTOP_IP}:${OPENCLAW_PUBLIC_PORT}/";
  ${HERMES_PUBLIC_HOST} "https://${CENTER_PUBLIC_HOST}/sso/openclaw";
  ${OPENCLAW_PUBLIC_HOST} "https://${CENTER_PUBLIC_HOST}/sso/openclaw";
}

server {
  listen ${CENTER_PORT};
  server_name _;
  allow 127.0.0.1;
  allow ${LAN_CIDR};
  deny all;

  location ^~ /api/ {
    proxy_pass http://127.0.0.1:${CENTER_INTERNAL_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$auto_agent_client_ip;
    proxy_set_header X-Forwarded-For \$auto_agent_client_ip;
    proxy_set_header X-Forwarded-Proto \$auto_agent_client_scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_connect_timeout 10s;
    proxy_send_timeout ${CENTER_API_TIMEOUT}s;
    proxy_read_timeout ${CENTER_API_TIMEOUT}s;
    proxy_buffering off;
  }

  location / {
    proxy_pass http://127.0.0.1:${CENTER_INTERNAL_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$auto_agent_client_ip;
    proxy_set_header X-Forwarded-For \$auto_agent_client_ip;
    proxy_set_header X-Forwarded-Proto \$auto_agent_client_scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_connect_timeout 10s;
  }
}

server {
  listen ${HERMES_PUBLIC_PORT};
  server_name _;
  allow 127.0.0.1;
  allow ${LAN_CIDR};
  deny all;

  location = /_auth {
    internal;
    proxy_pass http://127.0.0.1:${CENTER_INTERNAL_PORT}/auth/check;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Cookie \$http_cookie;
    proxy_set_header X-Forwarded-Proto \$auto_agent_client_scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Real-IP \$auto_agent_client_ip;
    proxy_set_header X-Forwarded-For \$auto_agent_client_ip;
  }

  location = /_auto_agent_sso {
    allow 127.0.0.1;
    deny all;
    proxy_pass http://127.0.0.1:${CENTER_INTERNAL_PORT}/_auto_agent_sso;
    proxy_http_version 1.1;
    proxy_set_header Cookie \$http_cookie;
    proxy_set_header X-Auto-Agent-SSO-Boundary 1;
    proxy_set_header X-Auto-Agent-SSO-Target hermes;
    proxy_set_header X-Forwarded-Proto \$auto_agent_client_scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Real-IP \$auto_agent_client_ip;
    proxy_set_header X-Forwarded-For \$auto_agent_client_ip;
  }

  location @login { return 302 \$auto_agent_login_url; }

  location / {
    auth_request /_auth;
    error_page 401 = @login;
    proxy_pass http://127.0.0.1:${HERMES_BACKEND_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host 127.0.0.1:${HERMES_BACKEND_PORT};
    proxy_set_header Origin http://127.0.0.1:${HERMES_BACKEND_PORT};
    proxy_set_header X-Real-IP \$auto_agent_client_ip;
    proxy_set_header X-Forwarded-For \$auto_agent_client_ip;
    proxy_set_header X-Forwarded-Proto \$auto_agent_client_scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$auto_agent_upgrade;
    proxy_set_header Accept-Encoding "";
    proxy_read_timeout 3600s;
    sub_filter_once on;
    sub_filter '<body>' '<body>${NAV}';
  }
}

server {
  listen ${OPENCLAW_PUBLIC_PORT};
  server_name _;
  allow 127.0.0.1;
  allow ${LAN_CIDR};
  deny all;

  location = /_auth {
    internal;
    proxy_pass http://127.0.0.1:${CENTER_INTERNAL_PORT}/auth/check;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Cookie \$http_cookie;
    proxy_set_header X-Forwarded-Proto \$auto_agent_client_scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Real-IP \$auto_agent_client_ip;
    proxy_set_header X-Forwarded-For \$auto_agent_client_ip;
  }

  location = /_auto_agent_sso {
    allow 127.0.0.1;
    deny all;
    proxy_pass http://127.0.0.1:${CENTER_INTERNAL_PORT}/_auto_agent_sso;
    proxy_http_version 1.1;
    proxy_set_header Cookie \$http_cookie;
    proxy_set_header X-Auto-Agent-SSO-Boundary 1;
    proxy_set_header X-Auto-Agent-SSO-Target openclaw;
    proxy_set_header X-Forwarded-Proto \$auto_agent_client_scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Real-IP \$auto_agent_client_ip;
    proxy_set_header X-Forwarded-For \$auto_agent_client_ip;
  }

  location @login { return 302 \$auto_agent_login_url; }

  location / {
    auth_request /_auth;
    error_page 401 = @login;
    proxy_pass http://127.0.0.1:${OPENCLAW_BACKEND_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host 127.0.0.1:${OPENCLAW_BACKEND_PORT};
    proxy_set_header X-Real-IP \$auto_agent_client_ip;
    proxy_set_header X-Forwarded-For \$auto_agent_client_ip;
    proxy_set_header X-Forwarded-Proto \$auto_agent_client_scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-User ${AUTO_AGENT_PROXY_IDENTITY};
    proxy_set_header Origin \$http_origin;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$auto_agent_upgrade;
    proxy_set_header Accept-Encoding "";
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
    sub_filter_once on;
    sub_filter '<body>' '<body>${NAV}';
  }
}
EOF2

if grep -qi 'Cf-Access-Jwt-Assertion' "$nginx_tmp"; then
  rm -f "$nginx_tmp"
  die "Refusing insecure Cloudflare-header authentication regression"
fi

sudo install -m 600 "$nginx_tmp" /etc/nginx/conf.d/auto-agent-control-center.conf
rm -f "$nginx_tmp"
sudo nginx -t
sudo systemctl enable --now nginx >/dev/null
sudo systemctl reload nginx
ok "Nginx temporary-cookie SSO boundary + safe forwarded-client attribution configured"
ok "Unified Chat API upstream timeout: ${CENTER_API_TIMEOUT}s"

if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
  for port in "$CENTER_PORT" "$HERMES_PUBLIC_PORT" "$OPENCLAW_PUBLIC_PORT"; do
    sudo ufw allow from "$LAN_CIDR" to any port "$port" proto tcp >/dev/null
  done
  ok "UFW permits control ports only from $LAN_CIDR; public ingress remains local cloudflared"
else
  ok "UFW inactive; Nginx LAN CIDR ACL + loopback cloudflared boundary enforced"
fi

mkdir -p "$HOME/.local/bin"
cat >"$HOME/.local/bin/auto-agent" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
CENTER_URL="http://${LAPTOP_IP}:${CENTER_PORT}"
PUBLIC_URL="https://${CENTER_PUBLIC_HOST}"
case "\${1:-status}" in
  center) echo "\$CENTER_URL"; command -v xdg-open >/dev/null 2>&1 && xdg-open "\$CENTER_URL" >/dev/null 2>&1 || true ;;
  public) echo "\$PUBLIC_URL"; command -v xdg-open >/dev/null 2>&1 && xdg-open "\$PUBLIC_URL" >/dev/null 2>&1 || true ;;
  credentials) grep -E '^AUTO_AGENT_CONTROL_(USERNAME|PASSWORD)=' "$ENV_FILE" ;;
  status)
    echo "Control Center : \$CENTER_URL"
    echo "Public Center  : \$PUBLIC_URL"
    echo "Center service : \$(systemctl --user is-active $UNIT 2>/dev/null || true)"
    echo "Hermes UI      : \$(systemctl --user is-active auto-agent-hermes-dashboard.service 2>/dev/null || true)"
    "$OPENCLAW" gateway status || true
    ;;
  restart)
    systemctl --user restart auto-agent-hermes-dashboard.service "$UNIT"
    sudo systemctl reload nginx
    ;;
  logs) journalctl --user -u "$UNIT" -u auto-agent-hermes-dashboard.service -n 250 --no-pager ;;
  *) echo "Usage: auto-agent {center|public|credentials|status|restart|logs}" >&2; exit 2 ;;
esac
EOF2
chmod 700 "$HOME/.local/bin/auto-agent"

curl -fsS --max-time 5 "http://${LAPTOP_IP}:${CENTER_PORT}/login" >/dev/null || die "LAN login page unreachable"
hcode="$(curl -sS -o /dev/null -w '%{http_code}' "http://${LAPTOP_IP}:${HERMES_PUBLIC_PORT}/" || true)"
code="$(curl -sS -o /dev/null -w '%{http_code}' "http://${LAPTOP_IP}:${OPENCLAW_PUBLIC_PORT}/" || true)"
[[ "$hcode" == 302 || "$hcode" == 303 || "$hcode" == 401 ]] || die "Hermes LAN proxy not protected: HTTP $hcode"
[[ "$code" == 302 || "$code" == 303 || "$code" == 401 ]] || die "OpenClaw LAN proxy not protected: HTTP $code"

public_missing=()
for host in "$CENTER_PUBLIC_HOST" "$HERMES_PUBLIC_HOST" "$OPENCLAW_PUBLIC_HOST"; do
  if getent ahostsv4 "$host" >/dev/null 2>&1 || getent ahosts "$host" >/dev/null 2>&1; then
    ok "Public DNS resolves: $host"
  else
    warn "Public DNS unresolved: $host"
    public_missing+=("$host")
  fi
done

printf '\n============================================================\n'
printf 'AUTO_AGENT UNIFIED CONTROL CENTER v0.5.9\n'
printf 'LAN URL         : http://%s:%s\n' "$LAPTOP_IP" "$CENTER_PORT"
printf 'Public URL      : https://%s\n' "$CENTER_PUBLIC_HOST"
printf 'Hermes public   : https://%s\n' "$HERMES_PUBLIC_HOST"
printf 'OpenClaw public : https://%s\n' "$OPENCLAW_PUBLIC_HOST"
printf 'Public auth     : Cloudflare Access + resilient Auto Agent SSO bridge\n'
printf 'SSO bridge      : HttpOnly Secure, path-limited, one-time, 180s TTL\n'
printf 'Native session  : host-only Secure cookie, 15m TTL with Workspace renewal\n'
printf 'Login user      : admin\n'
printf 'Password        : run "auto-agent credentials" on laptop\n'
printf 'LAN ACL         : %s\n' "$LAN_CIDR"
printf 'API timeout     : %ss\n' "$CENTER_API_TIMEOUT"
if ((${#public_missing[@]})); then
  printf 'Public edge     : PARTIAL — unresolved DNS: %s\n' "${public_missing[*]}"
else
  printf 'Public edge     : DNS resolution PASS for all configured hosts\n'
fi
printf '============================================================\n'
