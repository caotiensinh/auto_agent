#!/usr/bin/env bash
set -Eeuo pipefail
AUTO_AGENT_COMPONENT=unified-control

CENTER_PORT="${CONTROL_CENTER_PORT:-8088}"
CENTER_INTERNAL_PORT="${CONTROL_CENTER_INTERNAL_PORT:-18088}"
HERMES_BACKEND_PORT="${HERMES_DASHBOARD_PORT:-9119}"
OPENCLAW_BACKEND_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
HERMES_PUBLIC_PORT="${HERMES_PUBLIC_PORT:-9120}"
OPENCLAW_PUBLIC_PORT="${OPENCLAW_PUBLIC_PORT:-18790}"
REPO_RAW="${AUTO_AGENT_REPO_RAW:-https://raw.githubusercontent.com/caotiensinh/auto_agent/main}"
CFG_DIR="$HOME/.config/auto_agent"
ENV_FILE="$CFG_DIR/control.env"
APP_DIR="$HOME/.local/share/auto_agent"
APP_FILE="$APP_DIR/control_center.py"
UNIT="auto-agent-control-center.service"

log(){ printf '\033[1;34m[UNIFIED]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[UNIFIED:OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[UNIFIED:WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[UNIFIED:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run as normal Ubuntu user"
command -v sudo >/dev/null || die "sudo required"

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
sudo nginx -V 2>&1 | grep -q -- '--with-http_sub_module' || die "Ubuntu nginx lacks http_sub_module required for unified native navigation"

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

mkdir -p "$CFG_DIR" "$APP_DIR"; chmod 700 "$CFG_DIR" "$APP_DIR"
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
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
curl -fsSL --proto '=https' --tlsv1.2 "${REPO_RAW}/scripts/control_center.py" -o "$tmp"
python3 -m py_compile "$tmp" || die "control_center.py syntax invalid"
if ! cmp -s "$tmp" "$APP_FILE" 2>/dev/null; then
  install -m 700 "$tmp" "$APP_FILE"
  ok "Control Center app installed/updated"
else
  ok "Control Center app already current; reuse"
fi
rm -f "$tmp"

systemctl --user is-active --quiet auto-agent-hermes-dashboard.service \
  || systemctl --user start auto-agent-hermes-dashboard.service \
  || die "Hermes dashboard service not running"

# Apply OpenClaw's trusted-proxy configuration as one atomic patch. Batch/patch
# validation sees only the final state, avoiding transient invalid auth modes.
python3 - "$OPENCLAW_LOCAL_PASSWORD" "$LAPTOP_IP" "$OPENCLAW_PUBLIC_PORT" "$AUTO_AGENT_PROXY_IDENTITY" <<'PY' \
  | "$OPENCLAW" config patch --stdin >/dev/null
import json,sys
password, ip, port, identity = sys.argv[1:]
print(json.dumps({
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "trustedProxies": ["127.0.0.1"],
    "auth": {
      "mode": "trusted-proxy",
      "token": None,
      "password": password,
      "identityScopes": {identity: ["operator.admin"]},
      "trustedProxy": {
        "userHeader": "x-forwarded-user",
        "requiredHeaders": ["x-forwarded-proto", "x-forwarded-host"],
        "allowLoopback": True,
        "allowUsers": [identity]
      }
    },
    "controlUi": {
      "allowedOrigins": [f"http://{ip}:{port}"]
    },
    "http": {
      "endpoints": {
        "chatCompletions": {"enabled": True}
      }
    }
  }
}))
PY
"$OPENCLAW" config validate >/dev/null || die "OpenClaw unified-control config validation failed"
"$OPENCLAW" gateway restart --safe >/dev/null 2>&1 || "$OPENCLAW" gateway restart >/dev/null 2>&1 || true
ok "OpenClaw loopback gateway configured for authenticated trusted proxy + chat API"

mkdir -p "$HOME/.config/systemd/user"
unit_path="$HOME/.config/systemd/user/$UNIT"
cat >"$unit_path" <<EOF2
[Unit]
Description=auto_agent Unified Control Center
After=network-online.target auto-agent-hermes-dashboard.service
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=$HOME
Environment=PATH=$PATH
EnvironmentFile=$ENV_FILE
Environment=AUTO_AGENT_CENTER_HOST=127.0.0.1
Environment=AUTO_AGENT_CENTER_PORT=$CENTER_INTERNAL_PORT
Environment=AUTO_AGENT_HERMES_PUBLIC_PORT=$HERMES_PUBLIC_PORT
Environment=AUTO_AGENT_OPENCLAW_PUBLIC_PORT=$OPENCLAW_PUBLIC_PORT
Environment=AUTO_AGENT_HERMES_BIN=$HERMES
Environment=AUTO_AGENT_OPENCLAW_BIN=$OPENCLAW
Environment=AUTO_AGENT_OPENCLAW_URL=http://127.0.0.1:$OPENCLAW_BACKEND_PORT
ExecStart=/usr/bin/python3 $APP_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF2
chmod 600 "$unit_path"
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT" >/dev/null

for _ in $(seq 1 30); do
  curl -fsS --max-time 2 "http://127.0.0.1:${CENTER_INTERNAL_PORT}/login" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --max-time 3 "http://127.0.0.1:${CENTER_INTERNAL_PORT}/login" >/dev/null || die "Control Center backend failed"

NAV='<div id="auto-agent-nav" style="position:fixed;top:8px;right:8px;z-index:2147483647;background:#111827;color:#fff;padding:8px 10px;border-radius:9px;font:13px sans-serif;box-shadow:0 4px 18px #0008"><a style="color:#fff;text-decoration:none;margin-right:10px" href="http://'"$LAPTOP_IP"':'"$CENTER_PORT"'/">Auto Agent</a><a style="color:#fff;text-decoration:none;margin-right:10px" href="http://'"$LAPTOP_IP"':'"$HERMES_PUBLIC_PORT"'/">Hermes</a><a style="color:#fff;text-decoration:none" href="http://'"$LAPTOP_IP"':'"$OPENCLAW_PUBLIC_PORT"'/">OpenClaw</a></div>'

nginx_tmp="$(mktemp)"
cat >"$nginx_tmp" <<EOF2
# Managed by caotiensinh/auto_agent
map \$http_upgrade \$auto_agent_upgrade { default upgrade; '' close; }

server {
  listen ${CENTER_PORT};
  server_name _;
  allow 127.0.0.1;
  allow ${LAN_CIDR};
  deny all;
  location / {
    proxy_pass http://127.0.0.1:${CENTER_INTERNAL_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
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
  }
  location @login { return 302 http://${LAPTOP_IP}:${CENTER_PORT}/login; }
  location / {
    auth_request /_auth;
    error_page 401 = @login;
    proxy_pass http://127.0.0.1:${HERMES_BACKEND_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host 127.0.0.1:${HERMES_BACKEND_PORT};
    proxy_set_header Origin http://127.0.0.1:${HERMES_BACKEND_PORT};
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$auto_agent_upgrade;
    proxy_set_header Accept-Encoding "";
    proxy_read_timeout 3600s;
    sub_filter_types text/html;
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
  }
  location @login { return 302 http://${LAPTOP_IP}:${CENTER_PORT}/login; }
  location / {
    auth_request /_auth;
    error_page 401 = @login;
    proxy_pass http://127.0.0.1:${OPENCLAW_BACKEND_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host 127.0.0.1:${OPENCLAW_BACKEND_PORT};
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-User ${AUTO_AGENT_PROXY_IDENTITY};
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$auto_agent_upgrade;
    proxy_set_header Accept-Encoding "";
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
    sub_filter_types text/html;
    sub_filter_once on;
    sub_filter '<body>' '<body>${NAV}';
  }
}
EOF2
sudo install -m 600 "$nginx_tmp" /etc/nginx/conf.d/auto-agent-control-center.conf
rm -f "$nginx_tmp"
sudo nginx -t
sudo systemctl enable --now nginx >/dev/null
sudo systemctl reload nginx
ok "Nginx single-login proxy configured with LAN CIDR ACL"

if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
  for port in "$CENTER_PORT" "$HERMES_PUBLIC_PORT" "$OPENCLAW_PUBLIC_PORT"; do
    sudo ufw allow from "$LAN_CIDR" to any port "$port" proto tcp >/dev/null
  done
  ok "UFW also permits control ports only from $LAN_CIDR"
else
  ok "UFW inactive; Nginx LAN CIDR ACL remains enforced"
fi

cat >"$HOME/.local/bin/auto-agent" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
CENTER_URL="http://${LAPTOP_IP}:${CENTER_PORT}"
case "\${1:-status}" in
  center) echo "\$CENTER_URL"; command -v xdg-open >/dev/null 2>&1 && xdg-open "\$CENTER_URL" >/dev/null 2>&1 || true ;;
  credentials) grep -E '^AUTO_AGENT_CONTROL_(USERNAME|PASSWORD)=' "$ENV_FILE" ;;
  status)
    echo "Control Center : \$CENTER_URL"
    echo "Center service : \$(systemctl --user is-active $UNIT 2>/dev/null || true)"
    echo "Hermes UI      : \$(systemctl --user is-active auto-agent-hermes-dashboard.service 2>/dev/null || true)"
    "$OPENCLAW" gateway status || true
    ;;
  restart)
    systemctl --user restart auto-agent-hermes-dashboard.service "$UNIT"
    "$OPENCLAW" gateway restart --safe 2>/dev/null || "$OPENCLAW" gateway restart || true
    sudo systemctl reload nginx
    ;;
  logs) journalctl --user -u "$UNIT" -u auto-agent-hermes-dashboard.service -n 250 --no-pager ;;
  *) echo "Usage: auto-agent {center|credentials|status|restart|logs}" >&2; exit 2 ;;
esac
EOF2
chmod 700 "$HOME/.local/bin/auto-agent"

curl -fsS --max-time 5 "http://${LAPTOP_IP}:${CENTER_PORT}/login" >/dev/null || die "LAN login page unreachable"
hcode="$(curl -sS -o /dev/null -w '%{http_code}' "http://${LAPTOP_IP}:${HERMES_PUBLIC_PORT}/" || true)"
ocode="$(curl -sS -o /dev/null -w '%{http_code}' "http://${LAPTOP_IP}:${OPENCLAW_PUBLIC_PORT}/" || true)"
[[ "$hcode" == 302 || "$hcode" == 303 || "$hcode" == 401 ]] || die "Hermes proxy not protected: HTTP $hcode"
[[ "$ocode" == 302 || "$ocode" == 303 || "$ocode" == 401 ]] || die "OpenClaw proxy not protected: HTTP $ocode"

printf '\n============================================================\n'
printf 'AUTO_AGENT UNIFIED CONTROL CENTER READY\n'
printf 'URL            : http://%s:%s\n' "$LAPTOP_IP" "$CENTER_PORT"
printf 'Login user     : admin\n'
printf 'Password       : run "auto-agent credentials" on laptop\n'
printf 'Router         : @hermes / @openclaw / Auto\n'
printf 'Native menu    : Auto Agent / Hermes / OpenClaw\n'
printf 'LAN client     : browser only; no install required\n'
printf 'LAN ACL        : %s\n' "$LAN_CIDR"
printf '============================================================\n'