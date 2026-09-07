#!/usr/bin/env python3
"""Auto Agent Control Center async-chat wrapper.

Long AI work is submitted as a short HTTP request and executed in a background
worker. Runtime limits are owned by the selected agent, not by Auto Agent:

* Hermes: agent.run_budget_seconds (default null = no hard wall-clock cap).
  agent.gateway_timeout is inactivity-only metadata and is not treated as a
  maximum run duration.
* OpenClaw: agents.defaults.timeoutSeconds (current upstream default 172800s /
  48h; 0 = unlimited).

Auto Agent resolves the installed agent's effective configuration and only adds
small transport grace around a finite upstream hard limit. If the upstream
policy is unlimited, Auto Agent does not invent a shorter limit.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlparse
import hashlib
import hmac
import importlib.util
import ipaddress
import json
import os
import re
import secrets
import subprocess
import threading
import time
import urllib.request

APP_DIR = Path(os.environ.get("AUTO_AGENT_APP_DIR", Path.home() / ".local/share/auto_agent"))
BASE = APP_DIR / "control_center_v2.py"
UI = APP_DIR / "control_center_ui.html"
ASYNC_JS = APP_DIR / "control_center_async.js"

for required in (BASE, UI, ASYNC_JS):
    if not required.is_file():
        raise SystemExit(f"Missing Control Center component: {required}")

spec = importlib.util.spec_from_file_location("auto_agent_control_backend", BASE)
backend = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(backend)

ui = UI.read_text(encoding="utf-8")
required_markers = ('id="messages"', 'id="prompt"', 'id="mode"', 'id="send"', '__CENTER_PUBLIC_HOST__')
missing = [marker for marker in required_markers if marker not in ui]
if missing:
    raise SystemExit(f"UI template missing required markers: {missing}")

ASYNC_ASSET_PATH = "/_auto_agent_async.js"
if "</body>" not in ui:
    raise SystemExit("UI template has no </body> marker")
ui = ui.replace("</body>", f'<script src="{ASYNC_ASSET_PATH}?v=062-runtime-aware"></script>\n</body>', 1)
backend.APP_HTML = ui
ASYNC_JS_BYTES = ASYNC_JS.read_bytes()

JOBS = {}
JOB_LOCK = threading.Lock()
EXECUTOR = ThreadPoolExecutor(
    max_workers=int(os.environ.get("AUTO_AGENT_CHAT_WORKERS", "2")),
    thread_name_prefix="auto-agent-chat",
)
# Retention applies only AFTER a job is terminal. It is not a run timeout.
JOB_TTL = int(os.environ.get("AUTO_AGENT_CHAT_JOB_TTL", "1800"))
MAX_ACTIVE_JOBS = int(os.environ.get("AUTO_AGENT_CHAT_MAX_ACTIVE", "4"))
MAX_STORED_JOBS = int(os.environ.get("AUTO_AGENT_CHAT_MAX_STORED", "128"))
POLICY_CACHE_TTL = int(os.environ.get("AUTO_AGENT_RUNTIME_POLICY_CACHE_TTL", "30"))
POLICY_LOCK = threading.Lock()
POLICY_CACHE = {}


def now_ts():
    return time.time()


def agent_env():
    env = dict(os.environ)
    env["PATH"] = ":".join([
        os.path.expanduser("~/.local/bin"),
        os.path.expanduser("~/.hermes/bin"),
        os.path.expanduser("~/.hermes/node/bin"),
        os.path.expanduser("~/.openclaw/bin"),
        env.get("PATH", ""),
    ])
    return env


def config_get(cmd):
    """Return (value_text, resolved_ok) for an agent config command."""
    try:
        cp = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=8,
            env=agent_env(),
        )
    except Exception:
        return "", False
    text = (cp.stdout or "").strip()
    if cp.returncode != 0:
        return text, False
    # Config CLIs may print decoration before the scalar. Prefer the last
    # non-empty line; parse_duration also tolerates plain JSON/scalars.
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return (lines[-1] if lines else ""), True


def parse_duration(value, default=None):
    """Normalize a scalar duration. None means unlimited/no hard cap."""
    if value is None:
        return default
    raw = str(value).strip().strip('"\'').lower()
    if raw in {"", "none", "null", "unlimited", "infinite", "infinity", "inf", "undefined", "off", "false"}:
        return None
    try:
        number = float(raw)
    except ValueError:
        match = re.search(r"(?<![\w.])-?\d+(?:\.\d+)?", raw)
        if not match:
            return default
        number = float(match.group(0))
    if number <= 0:
        return None
    return int(number)


def explicit_env_limit(name):
    if name not in os.environ:
        return None, False
    return parse_duration(os.environ.get(name), None), True


def resolve_hermes_policy():
    override, has_override = explicit_env_limit("AUTO_AGENT_HERMES_RUN_LIMIT_SECONDS")
    if has_override:
        hard = override
        hard_source = "AUTO_AGENT_HERMES_RUN_LIMIT_SECONDS"
    else:
        raw, ok = config_get([backend.HERMES, "config", "get", "agent.run_budget_seconds"])
        hard = parse_duration(raw, None) if ok else None
        hard_source = "hermes:agent.run_budget_seconds" if ok else "hermes-upstream-default-unlimited"

    idle_raw, idle_ok = config_get([backend.HERMES, "config", "get", "agent.gateway_timeout"])
    inactivity = parse_duration(idle_raw, 1800) if idle_ok else 1800

    return {
        "agent": "hermes",
        "hard_limit_seconds": hard,
        "hard_limit_source": hard_source,
        "inactivity_timeout_seconds": inactivity,
        "inactivity_semantics": "resets on agent progress; not a wall-clock cap",
        "unlimited": hard is None,
    }


def resolve_openclaw_policy():
    override, has_override = explicit_env_limit("AUTO_AGENT_OPENCLAW_RUN_LIMIT_SECONDS")
    if has_override:
        hard = override
        source = "AUTO_AGENT_OPENCLAW_RUN_LIMIT_SECONDS"
    else:
        raw, ok = config_get([backend.OPENCLAW_BIN, "config", "get", "agents.defaults.timeoutSeconds"])
        # Current OpenClaw upstream default is 172800s (48h). The config CLI
        # normally returns the resolved default. Keep this fallback only for a
        # missing/broken config CLI, and mark the source explicitly.
        hard = parse_duration(raw, 172800) if ok else 172800
        source = "openclaw:agents.defaults.timeoutSeconds" if ok else "openclaw-upstream-default-172800"

    return {
        "agent": "openclaw",
        "hard_limit_seconds": hard,
        "hard_limit_source": source,
        "inactivity_timeout_seconds": None,
        "inactivity_semantics": "runtime-owned provider/backend liveness rules apply",
        "unlimited": hard is None,
    }


def resolve_runtime_policy(agent, force=False):
    now = now_ts()
    with POLICY_LOCK:
        cached = POLICY_CACHE.get(agent)
        if not force and cached and now - cached["cached_at"] < POLICY_CACHE_TTL:
            return dict(cached["policy"])

    policy = resolve_openclaw_policy() if agent == "openclaw" else resolve_hermes_policy()
    with POLICY_LOCK:
        POLICY_CACHE[agent] = {"cached_at": now, "policy": dict(policy)}
    return policy


def transport_timeout(policy):
    """External leak guard derived from a finite agent-owned wall-clock cap."""
    hard = policy.get("hard_limit_seconds")
    if hard is None:
        return None
    grace = max(60, min(600, int(hard * 0.05)))
    return hard + grace


def run_hermes(message, policy):
    timeout = transport_timeout(policy)
    cp = subprocess.run(
        [backend.HERMES, "-z", message],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        env=agent_env(),
    )
    if cp.returncode != 0:
        detail = (cp.stderr or cp.stdout or "Hermes failed").strip()
        raise RuntimeError(detail[-4000:])
    return cp.stdout.strip()


def run_openclaw(message, conversation_id, client_ip, policy):
    payload = json.dumps({
        "model": "openclaw/default",
        "user": f"auto-agent:{conversation_id}",
        "messages": [{"role": "user", "content": message}],
        "stream": False,
    }).encode()
    headers = {"Content-Type": "application/json"}
    ip = backend.valid_ip(client_ip)
    if ip and not ipaddress.ip_address(ip).is_loopback:
        headers.update({
            "X-Forwarded-For": ip,
            "X-Real-IP": ip,
            "X-Forwarded-User": backend.PROXY_IDENTITY,
            "X-Forwarded-Proto": "https" if backend.CENTER_PUBLIC_HOST else "http",
            "X-Forwarded-Host": backend.CENTER_PUBLIC_HOST or "auto-agent-control-center",
        })
    else:
        headers["Authorization"] = f"Bearer {backend.OPENCLAW_LOCAL_PASSWORD}"
    req = urllib.request.Request(
        backend.OPENCLAW_URL.rstrip("/") + "/v1/chat/completions",
        data=payload,
        headers=headers,
        method="POST",
    )
    timeout = transport_timeout(policy)
    if timeout is None:
        response = urllib.request.urlopen(req)
    else:
        response = urllib.request.urlopen(req, timeout=timeout)
    with response:
        data = json.load(response)
    return data["choices"][0]["message"]["content"]


def cleanup_jobs_locked(now=None):
    now = now or now_ts()
    expired = [
        job_id for job_id, job in JOBS.items()
        if job.get("status") in {"done", "error"} and now - job.get("finished_at", now) > JOB_TTL
    ]
    for job_id in expired:
        JOBS.pop(job_id, None)

    if len(JOBS) > MAX_STORED_JOBS:
        finished = sorted(
            ((job.get("finished_at", job.get("created_at", 0)), job_id)
             for job_id, job in JOBS.items()
             if job.get("status") in {"done", "error"}),
            key=lambda item: item[0],
        )
        for _, job_id in finished[: max(0, len(JOBS) - MAX_STORED_JOBS)]:
            JOBS.pop(job_id, None)


def active_jobs_locked():
    return sum(1 for job in JOBS.values() if job.get("status") in {"queued", "running"})


def run_job(job_id, agent, routed_message, conversation_id, client_ip):
    with JOB_LOCK:
        job = JOBS.get(job_id)
        if not job:
            return
        job["status"] = "running"
        job["started_at"] = now_ts()
        policy = dict(job["runtime_policy"])

    try:
        if agent == "openclaw":
            answer = run_openclaw(routed_message, conversation_id, client_ip, policy)
        else:
            answer = run_hermes(routed_message, policy)
        with JOB_LOCK:
            job = JOBS.get(job_id)
            if job:
                job.update({
                    "status": "done",
                    "answer": answer,
                    "finished_at": now_ts(),
                })
    except subprocess.TimeoutExpired:
        hard = policy.get("hard_limit_seconds")
        detail = f"{agent} exceeded its configured runtime budget" + (f" ({hard}s)" if hard else "")
        with JOB_LOCK:
            job = JOBS.get(job_id)
            if job:
                job.update({"status": "error", "error": detail, "finished_at": now_ts()})
    except Exception as exc:
        with JOB_LOCK:
            job = JOBS.get(job_id)
            if job:
                job.update({
                    "status": "error",
                    "error": str(exc)[-4000:] or exc.__class__.__name__,
                    "finished_at": now_ts(),
                })


def hash_poll_token(value):
    return hashlib.sha256(value.encode()).hexdigest()


def job_token_valid(job, supplied):
    expected = job.get("poll_token_hash", "")
    return bool(expected and supplied and hmac.compare_digest(expected, hash_poll_token(supplied)))


class Handler(backend.Handler):
    server_version = "AutoAgentControl/0.6.2-runtime-aware"

    def send_js(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "application/javascript; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == ASYNC_ASSET_PATH:
            self.send_js(ASYNC_JS_BYTES)
            return

        prefix = "/api/chat/jobs/"
        if path.startswith(prefix):
            job_id = path[len(prefix):]
            if not job_id or len(job_id) > 128:
                self.send_json(400, {"error": "invalid_job_id"})
                return
            with JOB_LOCK:
                cleanup_jobs_locked()
                job = JOBS.get(job_id)
                snapshot = dict(job) if job else None
            if not snapshot:
                self.send_json(404, {"error": "job_not_found"})
                return
            supplied = self.headers.get("X-Auto-Agent-Job-Token", "")
            if not self.authed() and not job_token_valid(snapshot, supplied):
                self.send_json(401, {"error": "unauthorized"})
                return
            payload = {
                "job_id": job_id,
                "status": snapshot["status"],
                "agent": snapshot["agent"],
                "conversation_id": snapshot["conversation_id"],
                "created_at": snapshot["created_at"],
                "runtime_policy": snapshot.get("runtime_policy", {}),
            }
            if snapshot["status"] == "done":
                payload["answer"] = snapshot.get("answer", "")
                payload["duration_ms"] = int((snapshot.get("finished_at", now_ts()) - snapshot.get("started_at", snapshot["created_at"])) * 1000)
            elif snapshot["status"] == "error":
                payload["error"] = snapshot.get("error", "Agent execution failed")
            else:
                payload["retry_after_ms"] = 1200
                if snapshot.get("started_at"):
                    payload["elapsed_ms"] = int((now_ts() - snapshot["started_at"]) * 1000)
            self.send_json(200, payload)
            return

        super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/api/chat":
            super().do_POST()
            return

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
            agent, routed = backend.route_message(mode, message)
            if not routed:
                raise ValueError("message is empty after agent routing prefix")
        except Exception as exc:
            self.send_json(400, {"error": str(exc)[-1000:]})
            return

        client_ip = self.real_client_ip()
        job_id = secrets.token_urlsafe(24)
        poll_token = secrets.token_urlsafe(32)
        created = now_ts()
        runtime_policy = resolve_runtime_policy(agent)

        with JOB_LOCK:
            cleanup_jobs_locked(created)
            if active_jobs_locked() >= MAX_ACTIVE_JOBS:
                self.send_json(429, {
                    "error": "too_many_active_jobs",
                    "message": "Auto Agent is already processing the maximum number of concurrent requests.",
                    "retry_after_ms": 3000,
                })
                return
            JOBS[job_id] = {
                "status": "queued",
                "agent": agent,
                "conversation_id": conversation_id,
                "created_at": created,
                "runtime_policy": runtime_policy,
                "poll_token_hash": hash_poll_token(poll_token),
            }

        EXECUTOR.submit(run_job, job_id, agent, routed, conversation_id, client_ip)
        self.send_json(202, {
            "job_id": job_id,
            "status": "queued",
            "agent": agent,
            "conversation_id": conversation_id,
            "poll_url": f"/api/chat/jobs/{job_id}",
            "poll_token": poll_token,
            "retry_after_ms": 800,
            "runtime_policy": runtime_policy,
        })


if __name__ == "__main__":
    hermes_policy = resolve_runtime_policy("hermes", force=True)
    openclaw_policy = resolve_runtime_policy("openclaw", force=True)
    print(
        "[control-center-async] runtime policies: "
        f"Hermes hard={hermes_policy.get('hard_limit_seconds') or 'unlimited'}s "
        f"(idle={hermes_policy.get('inactivity_timeout_seconds') or 'unlimited'}s); "
        f"OpenClaw hard={openclaw_policy.get('hard_limit_seconds') or 'unlimited'}s"
    )
    server = backend.ThreadingHTTPServer((backend.HOST, backend.PORT), Handler)
    print(f"[control-center-async] listening on {backend.HOST}:{backend.PORT}; agent-owned runtime budgets")
    server.serve_forever()
