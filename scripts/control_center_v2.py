#!/usr/bin/env python3
import base64
import hashlib
import hmac
import html
import http.cookies
import ipaddress
import json
import os
import secrets
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HOST = os.environ.get("AUTO_AGENT_CENTER_HOST", "127.0.0.1")
PORT = int(os.environ.get("AUTO_AGENT_CENTER_PORT", "18088"))
USERNAME = os.environ.get("AUTO_AGENT_CONTROL_USERNAME", "admin")
PASSWORD = os.environ.get("AUTO_AGENT_CONTROL_PASSWORD", "")
SESSION_SECRET = os.environ.get("AUTO_AGENT_SESSION_SECRET", "")
SESSION_TTL = int(os.environ.get("AUTO_AGENT_SESSION_TTL", "43200"))
NATIVE_SESSION_TTL = int(os.environ.get("AUTO_AGENT_NATIVE_SESSION_TTL", "900"))
SSO_TTL = int(os.environ.get("AUTO_AGENT_SSO_TTL", "180"))
PUBLIC_DOMAIN = os.environ.get("AUTO_AGENT_PUBLIC_DOMAIN", "").strip().lower().lstrip(".")

HERMES = os.environ.get("AUTO_AGENT_HERMES_BIN", os.path.expanduser("~/.local/bin/hermes"))
OPENCLAW_BIN = os.environ.get("AUTO_AGENT_OPENCLAW_BIN", os.path.expanduser("~/.local/bin/openclaw"))
OPENCLAW_URL = os.environ.get("AUTO_AGENT_OPENCLAW_URL", "http://127.0.0.1:18789")
OPENCLAW_LOCAL_PASSWORD = os.environ.get("OPENCLAW_LOCAL_PASSWORD", "")
PROXY_IDENTITY = os.environ.get("AUTO_AGENT_PROXY_IDENTITY", "auto-agent-admin")

HERMES_PUBLIC_PORT = int(os.environ.get("AUTO_AGENT_HERMES_PUBLIC_PORT", "9120"))
OPENCLAW_PUBLIC_PORT = int(os.environ.get("AUTO_AGENT_OPENCLAW_PUBLIC_PORT", "18790"))
CENTER_PUBLIC_HOST = os.environ.get("AUTO_AGENT_CENTER_PUBLIC_HOST", "").strip().lower()
HERMES_PUBLIC_HOST = os.environ.get("AUTO_AGENT_HERMES_PUBLIC_HOST", "").strip().lower()
OPENCLAW_PUBLIC_HOST = os.environ.get("AUTO_AGENT_OPENCLAW_PUBLIC_HOST", "").strip().lower()

if not PASSWORD or not SESSION_SECRET or not OPENCLAW_LOCAL_PASSWORD:
    raise SystemExit("Control Center credentials are incomplete")
if not PUBLIC_DOMAIN:
    raise SystemExit("AUTO_AGENT_PUBLIC_DOMAIN is required for secure native SSO handoff")

FAILED_LOGINS = {}
LOGIN_WINDOW = 300
LOGIN_MAX_ATTEMPTS = 8
USED_SSO_NONCES = {}
SSO_LOCK = threading.Lock()
SSO_BRIDGE_COOKIE = "__Secure-auto_agent_sso_bridge"
SSO_HOSTS = {
    "hermes": HERMES_PUBLIC_HOST,
    "openclaw": OPENCLAW_PUBLIC_HOST,
}

for _name, _host in (("workspace", CENTER_PUBLIC_HOST), *SSO_HOSTS.items()):
    if not _host or not (_host == PUBLIC_DOMAIN or _host.endswith("." + PUBLIC_DOMAIN)):
        raise SystemExit(f"{_name} public host must be inside AUTO_AGENT_PUBLIC_DOMAIN")


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def b64u_decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + ("=" * (-len(value) % 4)))


def sign(value: str) -> str:
    return b64u(hmac.new(SESSION_SECRET.encode(), value.encode(), hashlib.sha256).digest())


def make_session(ttl: int = SESSION_TTL) -> str:
    exp = int(time.time()) + ttl
    nonce = secrets.token_hex(8)
    body = f"{USERNAME}|{exp}|{nonce}"
    return f"{b64u(body.encode())}.{sign('session:' + body)}"


def validate_session(token: str) -> bool:
    try:
        payload, sig = token.split(".", 1)
        body = b64u_decode(payload).decode()
        user, exp, _ = body.split("|", 2)
        return (
            user == USERNAME
            and int(exp) >= int(time.time())
            and hmac.compare_digest(sign("session:" + body), sig)
        )
    except Exception:
        try:
            payload, sig = token.split(".", 1)
            body = b64u_decode(payload).decode()
            user, exp, _ = body.split("|", 2)
            return (
                user == USERNAME
                and int(exp) >= int(time.time())
                and hmac.compare_digest(sign(body), sig)
            )
        except Exception:
            return False


def make_sso_token(target: str) -> str:
    host = SSO_HOSTS.get(target, "")
    if not host:
        raise ValueError("public hostname missing")
    payload = {
        "v": 2,
        "purpose": "native-handoff",
        "iss": CENTER_PUBLIC_HOST,
        "target": target,
        "host": host,
        "exp": int(time.time()) + SSO_TTL,
        "nonce": secrets.token_urlsafe(18),
    }
    body = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    return f"{b64u(body.encode())}.{sign('sso:' + body)}"


def consume_sso_token(token: str, expected_target: str, expected_host: str) -> bool:
    try:
        payload_b64, sig = token.split(".", 1)
        body = b64u_decode(payload_b64).decode()
        if not hmac.compare_digest(sign("sso:" + body), sig):
            return False
        payload = json.loads(body)
        if payload.get("v") != 2 or payload.get("purpose") != "native-handoff":
            return False
        if payload.get("iss") != CENTER_PUBLIC_HOST:
            return False
        if payload.get("target") != expected_target:
            return False
        if payload.get("host") != expected_host:
            return False
        now = int(time.time())
        exp = int(payload.get("exp", 0))
        if exp < now or exp > now + SSO_TTL + 5:
            return False
        nonce = str(payload.get("nonce", ""))
        if not nonce:
            return False
        with SSO_LOCK:
            expired = [n for n, until in USED_SSO_NONCES.items() if until < now]
            for n in expired:
                USED_SSO_NONCES.pop(n, None)
            if nonce in USED_SSO_NONCES:
                return False
            USED_SSO_NONCES[nonce] = exp
        return True
    except Exception:
        return False


def valid_ip(value: str) -> str:
    try:
        return str(ipaddress.ip_address(value.strip()))
    except Exception:
        return ""


def safe_next(value: str) -> str:
    return value if value in {"/", "/sso/hermes", "/sso/openclaw"} else "/"


def route_message(mode: str, message: str):
    msg = message.strip()
    lower = msg.lower()
    if lower.startswith("@hermes"):
        return "hermes", msg[len("@hermes"):].lstrip(" :,-")
    if lower.startswith("@openclaw"):
        return "openclaw", msg[len("@openclaw"):].lstrip(" :,-")
    if lower.startswith("@auto"):
        mode = "auto"
        msg = msg[len("@auto"):].lstrip(" :,-")
        lower = msg.lower()
    if mode in ("hermes", "openclaw"):
        return mode, msg
    openclaw_terms = (
        "telegram", "discord", "slack", "whatsapp", "message", "messaging",
        "schedule", "calendar", "remind", "notify", "channel", "orchestrat",
        "automation", "cron", "gateway", "openclaw",
    )
    hermes_terms = (
        "code", "python", "bash", "shell", "ssh", "linux", "ubuntu", "network",
        "router", "switch", "camera", "debug", "log", "error", "fix", "github",
        "security", "cyber", "docker", "systemd", "nginx", "hermes",
    )
    if any(term in lower for term in openclaw_terms):
        return "openclaw", msg
    if any(term in lower for term in hermes_terms):
        return "hermes", msg
    return "hermes", msg


def run_hermes(message: str) -> str:
    env = dict(os.environ)
    env["PATH"] = ":".join([
        os.path.expanduser("~/.local/bin"),
        os.path.expanduser("~/.hermes/bin"),
        os.path.expanduser("~/.hermes/node/bin"),
        os.path.expanduser("~/.openclaw/bin"),
        env.get("PATH", ""),
    ])
    cp = subprocess.run(
        [HERMES, "-z", message],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=900,
        env=env,
    )
    if cp.returncode != 0:
        detail = (cp.stderr or cp.stdout or "Hermes failed").strip()
        raise RuntimeError(detail[-4000:])
    return cp.stdout.strip()


def run_openclaw(message: str, conversation_id: str, client_ip: str) -> str:
    payload = json.dumps({
        "model": "openclaw/default",
        "user": f"auto-agent:{conversation_id}",
        "messages": [{"role": "user", "content": message}],
        "stream": False,
    }).encode()
    headers = {"Content-Type": "application/json"}
    ip = valid_ip(client_ip)
    if ip and not ipaddress.ip_address(ip).is_loopback:
        headers.update({
            "X-Forwarded-For": ip,
            "X-Real-IP": ip,
            "X-Forwarded-User": PROXY_IDENTITY,
            "X-Forwarded-Proto": "https" if CENTER_PUBLIC_HOST else "http",
            "X-Forwarded-Host": CENTER_PUBLIC_HOST or "auto-agent-control-center",
        })
    else:
        headers["Authorization"] = f"Bearer {OPENCLAW_LOCAL_PASSWORD}"
    req = urllib.request.Request(
        OPENCLAW_URL.rstrip("/") + "/v1/chat/completions",
        data=payload,
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=900) as response:
        data = json.load(response)
    return data["choices"][0]["message"]["content"]


def command_output(cmd):
    try:
        cp = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=20,
        )
        return cp.stdout[-8000:], cp.returncode == 0
    except Exception as exc:
        return str(exc), False


LOGIN_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Auto Agent Login</title>
<style>
body{font-family:system-ui;background:#0f172a;color:#e2e8f0;display:grid;place-items:center;height:100vh;margin:0}
.card{width:min(360px,90vw);background:#111827;padding:28px;border-radius:16px;box-shadow:0 20px 60px #0008}
input,button{box-sizing:border-box;width:100%;padding:12px;margin-top:10px;border-radius:10px;border:1px solid #334155}
input{background:#0b1220;color:#fff}button{background:#2563eb;color:#fff;border:0;font-weight:700;cursor:pointer}
.small{color:#94a3b8;font-size:13px}.err{color:#fca5a5}
</style></head><body><form class="card" method="post" action="/login">
<h2>Auto Agent Control Center</h2><div class="small">Hermes + OpenClaw · secure unified login</div>
__ERROR__<input type="hidden" name="next" value="__NEXT__">
<input name="username" placeholder="Username" autocomplete="username" required>
<input name="password" type="password" placeholder="Password" autocomplete="current-password" required>
<button type="submit">Login</button></form></body></html>"""


def login_page(error: str = "", next_path: str = "/") -> str:
    return LOGIN_HTML.replace("__ERROR__", error).replace("__NEXT__", html.escape(safe_next(next_path), quote=True))


APP_HTML = r"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Auto Agent Control Center</title>
<style>
*{box-sizing:border-box}body{margin:0;font-family:system-ui;background:#0b1020;color:#e5e7eb}
header{height:58px;display:flex;align-items:center;gap:10px;padding:0 16px;background:#111827;border-bottom:1px solid #263247}
.brand{font-weight:800;margin-right:auto}.pill{font-size:12px;color:#93c5fd}
button{border:0;border-radius:9px;padding:9px 12px;background:#1f2937;color:#e5e7eb;cursor:pointer}button.active{background:#2563eb}.logout{background:#7f1d1d}
main{height:calc(100vh - 58px)}.panel{display:none;height:100%}.panel.active{display:block}
.chat{display:grid;grid-template-rows:1fr auto;height:100%}.messages{padding:18px;overflow:auto}
.msg{max-width:900px;margin:10px auto;padding:12px 14px;border-radius:12px;white-space:pre-wrap}.user{background:#1e3a5f}.agent{background:#18212f}.meta{font-size:12px;color:#93c5fd;margin-bottom:6px}
.composer{padding:12px;border-top:1px solid #263247;background:#0f172a;display:grid;grid-template-columns:auto 1fr auto;gap:8px}
select,input{background:#111827;color:#fff;border:1px solid #334155;border-radius:9px;padding:11px}.status{padding:18px;overflow:auto;height:100%}pre{white-space:pre-wrap;background:#111827;padding:14px;border-radius:10px}
</style></head><body>
<header><div class="brand">Auto Agent <span class="pill">Hermes + OpenClaw</span></div>
<button data-tab="chat" class="active">Unified Chat</button><button data-tab="hermes">Hermes</button><button data-tab="openclaw">OpenClaw</button><button data-tab="status">Status</button><button class="logout" onclick="location='/logout'">Logout</button></header>
<main>
<section id="chat" class="panel active"><div class="chat"><div id="messages" class="messages"><div class="msg agent"><div class="meta">Router</div>Use <b>@hermes</b> for technical/terminal/network/code tasks, <b>@openclaw</b> for messaging/orchestration/automation, or leave mode on Auto.</div></div>
<div class="composer"><select id="mode"><option value="auto">Auto</option><option value="hermes">Hermes</option><option value="openclaw">OpenClaw</option></select><input id="prompt" placeholder="@hermes kiểm tra network...  |  @openclaw gửi thông báo..." autofocus><button id="send">Send</button></div></div></section>
<section id="status" class="panel status"><button onclick="loadStatus()">Refresh</button><pre id="statusText">Loading...</pre></section>
</main>
<script>
const host=location.hostname;
const publicCenter='__CENTER_PUBLIC_HOST__';
const isPublic=publicCenter&&host===publicCenter;
const hermesUrl=isPublic?'/sso/hermes':`http://${host}:__HERMES_PORT__/`;
const openclawUrl=isPublic?'/sso/openclaw':`http://${host}:__OPENCLAW_PORT__/`;
let conv=(crypto.randomUUID?crypto.randomUUID():String(Date.now()));
function tab(name){if(name==='hermes'){location.href=hermesUrl;return}if(name==='openclaw'){location.href=openclawUrl;return}document.querySelectorAll('header button[data-tab]').forEach(b=>b.classList.toggle('active',b.dataset.tab===name));document.querySelectorAll('.panel').forEach(p=>p.classList.toggle('active',p.id===name));if(name==='status')loadStatus();}
document.querySelectorAll('header button[data-tab]').forEach(b=>b.onclick=()=>tab(b.dataset.tab));
function add(cls,meta,text){const d=document.createElement('div');d.className='msg '+cls;d.innerHTML=`<div class="meta">${meta}</div>`;d.append(document.createTextNode(text));document.getElementById('messages').append(d);d.scrollIntoView();}
async function jsonResponse(r){const text=await r.text();const ct=(r.headers.get('content-type')||'').toLowerCase();if(!ct.includes('application/json')){const preview=(text||'').replace(/\s+/g,' ').trim().slice(0,180);throw new Error(`HTTP ${r.status} ${r.statusText}: expected JSON, received ${ct||'unknown content-type'}${preview?` - ${preview}`:''}`);}let d;try{d=JSON.parse(text||'{}');}catch(e){throw new Error(`HTTP ${r.status}: malformed JSON response`);}if(!r.ok)throw new Error(d.error||`HTTP ${r.status} ${r.statusText}`);return d;}
async function send(){const input=document.getElementById('prompt');const message=input.value.trim();if(!message)return;input.value='';add('user','You',message);document.getElementById('send').disabled=true;try{const r=await fetch('/api/chat',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({message,mode:document.getElementById('mode').value,conversation_id:conv})});const d=await jsonResponse(r);add('agent',d.agent,d.answer);document.getElementById('mode').value=d.agent;}catch(e){add('agent','Error',String(e));}finally{document.getElementById('send').disabled=false;input.focus();}}
document.getElementById('send').onclick=send;document.getElementById('prompt').addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();send();}});
async function loadStatus(){try{const r=await fetch('/api/status');const d=await jsonResponse(r);document.getElementById('statusText').textContent=JSON.stringify(d,null,2);}catch(e){document.getElementById('statusText').textContent=String(e)}}
</script></body></html>"""


def app_page() -> str:
    return APP_HTML.replace("__CENTER_PUBLIC_HOST__", CENTER_PUBLIC_HOST).replace("__HERMES_PORT__", str(HERMES_PUBLIC_PORT)).replace("__OPENCLAW_PORT__", str(OPENCLAW_PUBLIC_PORT))


class Handler(BaseHTTPRequestHandler):
    server_version = "AutoAgentControl/0.5.9"

    def log_message(self, fmt, *args):
        try:
            ip = self.real_client_ip()
        except Exception:
            ip = self.client_address[0] if self.client_address else "unknown"
        print(f"[control-center] {ip} {fmt % args}")

    def real_client_ip(self):
        forwarded = self.headers.get("X-Forwarded-For", "").split(",", 1)[0].strip()
        real = self.headers.get("X-Real-IP", "").strip()
        return valid_ip(forwarded) or valid_ip(real) or self.client_address[0]

    def cookies(self):
        cookies = http.cookies.SimpleCookie()
        cookies.load(self.headers.get("Cookie", ""))
        return cookies

    def authed(self):
        cookies = self.cookies()
        token = cookies["auto_agent_session"].value if "auto_agent_session" in cookies else ""
        return validate_session(token)

    def request_is_https(self):
        return self.headers.get("X-Forwarded-Proto", "").split(",", 1)[0].strip().lower() == "https"

    def session_cookie(self, value: str, max_age: int):
        parts = [f"auto_agent_session={value}", "Path=/", "HttpOnly", "SameSite=Lax", f"Max-Age={max_age}"]
        if self.request_is_https():
            parts.append("Secure")
        return "; ".join(parts)

    def bridge_cookie(self, value: str, max_age: int):
        return "; ".join([
            f"{SSO_BRIDGE_COOKIE}={value}",
            f"Domain=.{PUBLIC_DOMAIN}",
            "Path=/_auto_agent_sso",
            "HttpOnly",
            "Secure",
            "SameSite=Lax",
            f"Max-Age={max_age}",
        ])

    def security_headers(self, csp=None):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", csp or "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")

    def send_html(self, code, body, extra_headers=None, csp=None):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.security_headers(csp=csp)
        if extra_headers:
            for key, value in extra_headers:
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.security_headers("default-src 'none'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, where, headers=None):
        self.send_response(303)
        self.send_header("Location", where)
        self.send_header("Cache-Control", "no-store")
        if headers:
            for key, value in headers:
                self.send_header(key, value)
        self.end_headers()

    def require_auth(self, next_path="/"):
        if self.authed():
            return True
        self.redirect("/login?next=" + safe_next(next_path))
        return False

    def read_form(self, limit=65536):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length < 0 or length > limit:
            raise ValueError("request too large")
        return parse_qs(self.rfile.read(length).decode(errors="replace"))

    def sso_start(self, target: str, retry: int = 0):
        host = SSO_HOSTS.get(target, "")
        if not host:
            self.send_html(503, "<h1>Public SSO target is not configured</h1>")
            return
        if not self.request_is_https():
            self.send_html(400, "<h1>Public native SSO requires HTTPS</h1>")
            return
        token = make_sso_token(target)
        attempt = 2 if retry else 1
        destination = f"https://{host}/_auto_agent_sso?attempt={attempt}"
        self.redirect(destination, [("Set-Cookie", self.bridge_cookie(token, SSO_TTL))])

    def validate_sso_boundary(self, target: str) -> tuple[bool, str]:
        boundary = self.headers.get("X-Auto-Agent-SSO-Boundary", "") == "1"
        forwarded_host = self.headers.get("X-Forwarded-Host", "").split(":", 1)[0].strip().lower()
        expected_host = SSO_HOSTS.get(target, "")
        ok = boundary and bool(expected_host) and forwarded_host == expected_host and self.request_is_https()
        return ok, expected_host

    def finish_sso(self, target: str, token: str, attempt: int):
        boundary_ok, expected_host = self.validate_sso_boundary(target)
        clear_bridge = ("Set-Cookie", self.bridge_cookie("", 0))
        if not boundary_ok:
            self.send_json(403, {"error": "invalid_sso_boundary"})
            return
        if token and consume_sso_token(token, target, expected_host):
            self.redirect("/", [
                ("Set-Cookie", self.session_cookie(make_session(NATIVE_SESSION_TTL), NATIVE_SESSION_TTL)),
                clear_bridge,
            ])
            return
        if attempt <= 1:
            retry_url = f"https://{CENTER_PUBLIC_HOST}/sso/{target}?retry=1"
            self.redirect(retry_url, [clear_bridge])
            return
        back = f"https://{CENTER_PUBLIC_HOST}/sso/{target}"
        body = (
            "<h1>Native SSO handoff failed</h1>"
            "<p>The temporary handoff cookie was missing, expired, or already used after the Cloudflare Access hop.</p>"
            f"<p><a href=\"{html.escape(back, quote=True)}\">Retry from Workspace</a></p>"
        )
        self.send_html(403, body, extra_headers=[clear_bridge])

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        if path == "/login":
            next_path = safe_next(query.get("next", ["/"])[0])
            if self.authed():
                self.redirect(next_path)
            else:
                self.send_html(200, login_page(next_path=next_path))
            return
        if path == "/logout":
            self.redirect("/login", [("Set-Cookie", self.session_cookie("", 0))])
            return
        if path == "/auth/check":
            if self.authed():
                self.send_response(204)
                self.send_header("X-Authenticated-User", USERNAME)
                self.end_headers()
            else:
                self.send_response(401)
                self.end_headers()
            return
        if path == "/_auto_agent_sso":
            target = self.headers.get("X-Auto-Agent-SSO-Target", "").strip().lower()
            try:
                attempt = max(1, min(2, int(query.get("attempt", ["1"])[0])))
            except Exception:
                attempt = 1
            cookies = self.cookies()
            token = cookies[SSO_BRIDGE_COOKIE].value if SSO_BRIDGE_COOKIE in cookies else ""
            self.finish_sso(target, token, attempt)
            return
        if path in ("/sso/hermes", "/sso/openclaw"):
            target = path.rsplit("/", 1)[-1]
            if not self.require_auth(path):
                return
            retry = 1 if query.get("retry", ["0"])[0] == "1" else 0
            self.sso_start(target, retry=retry)
            return
        if path == "/api/status":
            if not self.authed():
                self.send_json(401, {"error": "unauthorized"})
                return
            hgw, _ = command_output([HERMES, "gateway", "status"])
            hdb, _ = command_output(["systemctl", "--user", "is-active", "auto-agent-hermes-dashboard.service"])
            center, _ = command_output(["systemctl", "--user", "is-active", "auto-agent-control-center.service"])
            ogw, _ = command_output([OPENCLAW_BIN, "gateway", "status"])
            self.send_json(200, {"center": center.strip(), "hermes_dashboard": hdb.strip(), "hermes_gateway": hgw, "openclaw_gateway": ogw, "public_hosts": {"workspace": CENTER_PUBLIC_HOST, "hermes": HERMES_PUBLIC_HOST, "openclaw": OPENCLAW_PUBLIC_HOST}, "sso": {"mode": "temporary-domain-bridge", "ttl": SSO_TTL, "native_session_ttl": NATIVE_SESSION_TTL}})
            return
        if path == "/":
            if not self.require_auth("/"):
                return
            self.send_html(200, app_page())
            return
        self.send_html(404, "<h1>Not found</h1>")

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        if path == "/login":
            try:
                form = self.read_form(16384)
            except Exception:
                self.send_html(413, login_page("Invalid request"))
                return
            username = form.get("username", [""])[0]
            password = form.get("password", [""])[0]
            next_path = safe_next(form.get("next", ["/"])[0])
            ip = self.real_client_ip()
            now = time.time()
            attempts = [t for t in FAILED_LOGINS.get(ip, []) if now - t < LOGIN_WINDOW]
            FAILED_LOGINS[ip] = attempts
            if len(attempts) >= LOGIN_MAX_ATTEMPTS:
                self.send_html(429, login_page('<div class="err">Too many login attempts. Try again later.</div>', next_path))
                return
            if not (hmac.compare_digest(username, USERNAME) and hmac.compare_digest(password, PASSWORD)):
                attempts.append(now)
                FAILED_LOGINS[ip] = attempts
                self.send_html(401, login_page('<div class="err">Invalid username or password.</div>', next_path))
                return
            FAILED_LOGINS.pop(ip, None)
            self.redirect(next_path, [("Set-Cookie", self.session_cookie(make_session(), SESSION_TTL))])
            return
        if path == "/_auto_agent_sso":
            target = self.headers.get("X-Auto-Agent-SSO-Target", "").strip().lower()
            try:
                form = self.read_form(65536)
            except Exception:
                self.send_json(413, {"error": "invalid_sso_request"})
                return
            token = form.get("token", [""])[0]
            try:
                attempt = max(1, min(2, int(query.get("attempt", ["1"])[0])))
            except Exception:
                attempt = 1
            self.finish_sso(target, token, attempt)
            return
        if path == "/api/chat":
            if not self.authed():
                self.send_json(401, {"error": "unauthorized"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0") or 0)
                if length < 0 or length > 1024 * 1024:
                    raise ValueError("request too large")
                payload = json.loads(self.rfile.read(length) or b"{}")
                message = str(payload.get("message", "")).strip()
                mode = str(payload.get("mode", "auto"))
                conversation_id = str(payload.get("conversation_id", ""))[:128] or secrets.token_hex(8)
                if not message:
                    raise ValueError("message is required")
                agent, routed = route_message(mode, message)
                if agent == "openclaw":
                    answer = run_openclaw(routed, conversation_id, self.real_client_ip())
                else:
                    answer = run_hermes(routed)
                self.send_json(200, {"agent": agent, "answer": answer, "conversation_id": conversation_id})
            except Exception as exc:
                self.send_json(502, {"error": str(exc)[-4000:]})
            return
        self.send_json(404, {"error": "not found"})


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"[control-center] listening on {HOST}:{PORT}")
    server.serve_forever()
