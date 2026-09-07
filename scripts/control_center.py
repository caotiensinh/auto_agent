#!/usr/bin/env python3
import base64
import hashlib
import hmac
import http.cookies
import ipaddress
import json
import os
import secrets
import subprocess
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
HERMES = os.environ.get("AUTO_AGENT_HERMES_BIN", os.path.expanduser("~/.local/bin/hermes"))
OPENCLAW_BIN = os.environ.get("AUTO_AGENT_OPENCLAW_BIN", os.path.expanduser("~/.local/bin/openclaw"))
OPENCLAW_URL = os.environ.get("AUTO_AGENT_OPENCLAW_URL", "http://127.0.0.1:18789")
OPENCLAW_LOCAL_PASSWORD = os.environ.get("OPENCLAW_LOCAL_PASSWORD", "")
PROXY_IDENTITY = os.environ.get("AUTO_AGENT_PROXY_IDENTITY", "auto-agent-admin")
HERMES_PUBLIC_PORT = int(os.environ.get("AUTO_AGENT_HERMES_PUBLIC_PORT", "9119"))
OPENCLAW_PUBLIC_PORT = int(os.environ.get("AUTO_AGENT_OPENCLAW_PUBLIC_PORT", "18789"))

if not PASSWORD or not SESSION_SECRET or not OPENCLAW_LOCAL_PASSWORD:
    raise SystemExit("Control Center credentials are incomplete")

FAILED_LOGINS = {}
LOGIN_WINDOW = 300
LOGIN_MAX_ATTEMPTS = 8


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def sign(value: str) -> str:
    return b64u(hmac.new(SESSION_SECRET.encode(), value.encode(), hashlib.sha256).digest())


def make_session() -> str:
    exp = int(time.time()) + SESSION_TTL
    nonce = secrets.token_hex(8)
    body = f"{USERNAME}|{exp}|{nonce}"
    return f"{b64u(body.encode())}.{sign(body)}"


def validate_session(token: str) -> bool:
    try:
        payload, sig = token.split(".", 1)
        pad = "=" * (-len(payload) % 4)
        body = base64.urlsafe_b64decode(payload + pad).decode()
        user, exp, _ = body.split("|", 2)
        return (
            user == USERNAME
            and int(exp) >= int(time.time())
            and hmac.compare_digest(sign(body), sig)
        )
    except Exception:
        return False


def valid_ip(value: str) -> str:
    try:
        return str(ipaddress.ip_address(value.strip()))
    except Exception:
        return ""


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
            "X-Forwarded-User": PROXY_IDENTITY,
            "X-Forwarded-Proto": "http",
            "X-Forwarded-Host": "auto-agent-control-center",
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
<h2>Auto Agent Control Center</h2><div class="small">Hermes + OpenClaw · one LAN login</div>
__ERROR__<input name="username" placeholder="Username" autocomplete="username" required>
<input name="password" type="password" placeholder="Password" autocomplete="current-password" required>
<button type="submit">Login</button></form></body></html>"""


def login_page(error: str = "") -> str:
    return LOGIN_HTML.replace("__ERROR__", error)


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
const host=location.hostname;const hermesUrl=`http://${host}:__HERMES_PORT__/`;const openclawUrl=`http://${host}:__OPENCLAW_PORT__/`;let conv=(crypto.randomUUID?crypto.randomUUID():String(Date.now()));
function tab(name){if(name==='hermes'){location.href=hermesUrl;return}if(name==='openclaw'){location.href=openclawUrl;return}document.querySelectorAll('header button[data-tab]').forEach(b=>b.classList.toggle('active',b.dataset.tab===name));document.querySelectorAll('.panel').forEach(p=>p.classList.toggle('active',p.id===name));if(name==='status')loadStatus();}
document.querySelectorAll('header button[data-tab]').forEach(b=>b.onclick=()=>tab(b.dataset.tab));
function add(cls,meta,text){const d=document.createElement('div');d.className='msg '+cls;d.innerHTML=`<div class="meta">${meta}</div>`;d.append(document.createTextNode(text));document.getElementById('messages').append(d);d.scrollIntoView();}
async function jsonResponse(r){const text=await r.text();const ct=(r.headers.get('content-type')||'').toLowerCase();if(!ct.includes('application/json')){const preview=(text||'').replace(/\s+/g,' ').trim().slice(0,180);throw new Error(`HTTP ${r.status} ${r.statusText}: expected JSON, received ${ct||'unknown content-type'}${preview?` - ${preview}`:''}`);}let d;try{d=JSON.parse(text||'{}');}catch(e){throw new Error(`HTTP ${r.status}: malformed JSON response`);}if(!r.ok)throw new Error(d.error||`HTTP ${r.status} ${r.statusText}`);return d;}
async function send(){const input=document.getElementById('prompt');const message=input.value.trim();if(!message)return;input.value='';add('user','You',message);document.getElementById('send').disabled=true;try{const r=await fetch('/api/chat',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({message,mode:document.getElementById('mode').value,conversation_id:conv})});const d=await jsonResponse(r);add('agent',d.agent,d.answer);document.getElementById('mode').value=d.agent;}catch(e){add('agent','Error',String(e));}finally{document.getElementById('send').disabled=false;input.focus();}}
document.getElementById('send').onclick=send;document.getElementById('prompt').addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();send();}});
async function loadStatus(){try{const r=await fetch('/api/status');const d=await jsonResponse(r);document.getElementById('statusText').textContent=JSON.stringify(d,null,2);}catch(e){document.getElementById('statusText').textContent=String(e)}}
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "AutoAgentControl/0.4"

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

    def security_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
        )

    def send_html(self, code, body, extra_headers=None):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.security_headers()
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
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
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

    def require_auth(self):
        if self.authed():
            return True
        self.redirect("/login")
        return False

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/login":
            if self.authed():
                self.redirect("/")
            else:
                self.send_html(200, login_page())
            return
        if path == "/logout":
            self.redirect(
                "/login",
                [("Set-Cookie", "auto_agent_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0")],
            )
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
        if path == "/api/status":
            if not self.authed():
                self.send_json(401, {"error": "unauthorized"})
                return
            hgw, _ = command_output([HERMES, "gateway", "status"])
            hdb, _ = command_output(["systemctl", "--user", "is-active", "auto-agent-hermes-dashboard.service"])
            center, _ = command_output(["systemctl", "--user", "is-active", "auto-agent-control-center.service"])
            oc, _ = command_output([OPENCLAW_BIN, "gateway", "status"])
            self.send_json(200, {
                "control_center": center.strip(),
                "hermes_gateway": hgw.strip(),
                "hermes_dashboard": hdb.strip(),
                "openclaw_gateway": oc.strip(),
            })
            return
        if path == "/":
            if not self.require_auth():
                return
            body = APP_HTML.replace("__HERMES_PORT__", str(HERMES_PUBLIC_PORT)).replace(
                "__OPENCLAW_PORT__", str(OPENCLAW_PUBLIC_PORT)
            )
            self.send_html(200, body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        path = urlparse(self.path).path
        length = min(int(self.headers.get("Content-Length", "0") or "0"), 1024 * 1024)
        raw = self.rfile.read(length)
        if path == "/login":
            now = time.time()
            ip = self.real_client_ip()
            attempts = [stamp for stamp in FAILED_LOGINS.get(ip, []) if now - stamp < LOGIN_WINDOW]
            FAILED_LOGINS[ip] = attempts
            if len(attempts) >= LOGIN_MAX_ATTEMPTS:
                self.send_html(429, login_page('<p class="err">Too many failed logins. Try again later.</p>'))
                return
            form = parse_qs(raw.decode(errors="replace"))
            user = form.get("username", [""])[0]
            password = form.get("password", [""])[0]
            if hmac.compare_digest(user, USERNAME) and hmac.compare_digest(password, PASSWORD):
                FAILED_LOGINS.pop(ip, None)
                cookie = f"auto_agent_session={make_session()}; Path=/; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL}"
                self.redirect("/", [("Set-Cookie", cookie)])
            else:
                FAILED_LOGINS.setdefault(ip, []).append(now)
                self.send_html(401, login_page('<p class="err">Invalid username or password</p>'))
            return
        if path == "/api/chat":
            if not self.authed():
                self.send_json(401, {"error": "unauthorized"})
                return
            try:
                body = json.loads(raw or b"{}")
                message = str(body.get("message", "")).strip()
                mode = str(body.get("mode", "auto")).lower()
                conversation_id = str(body.get("conversation_id", "default"))[:128]
                if not message:
                    raise ValueError("message is required")
                agent, prompt = route_message(mode, message)
                if not prompt:
                    raise ValueError("message is empty after tag")
                if agent == "hermes":
                    answer = run_hermes(prompt)
                else:
                    answer = run_openclaw(prompt, conversation_id, self.real_client_ip())
                self.send_json(200, {"agent": agent, "answer": answer})
            except subprocess.TimeoutExpired:
                self.send_json(504, {"error": "agent timeout"})
            except Exception as exc:
                self.send_json(500, {"error": str(exc)[-4000:]})
            return
        self.send_response(404)
        self.end_headers()


if __name__ == "__main__":
    print(f"[control-center] listening on http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
