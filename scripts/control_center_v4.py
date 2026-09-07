#!/usr/bin/env python3
"""Auto Agent Control Center async-chat wrapper.

The base control_center_v2.py owns authentication, SSO, routing and agent calls.
This wrapper keeps those boundaries intact while changing /api/chat into a
short request + status-polling workflow so long local-model tasks do not sit
behind Cloudflare's proxy read timeout.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlparse
import importlib.util
import json
import os
import secrets
import threading
import time

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
ui = ui.replace("</body>", f'<script src="{ASYNC_ASSET_PATH}?v=061-chatfix"></script>\n</body>', 1)
backend.APP_HTML = ui
ASYNC_JS_BYTES = ASYNC_JS.read_bytes()

JOBS = {}
JOB_LOCK = threading.Lock()
EXECUTOR = ThreadPoolExecutor(max_workers=2, thread_name_prefix="auto-agent-chat")
JOB_TTL = int(os.environ.get("AUTO_AGENT_CHAT_JOB_TTL", "1800"))
MAX_ACTIVE_JOBS = int(os.environ.get("AUTO_AGENT_CHAT_MAX_ACTIVE", "4"))
MAX_STORED_JOBS = int(os.environ.get("AUTO_AGENT_CHAT_MAX_STORED", "128"))


def now_ts():
    return time.time()


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

    try:
        if agent == "openclaw":
            answer = backend.run_openclaw(routed_message, conversation_id, client_ip)
        else:
            answer = backend.run_hermes(routed_message)
        with JOB_LOCK:
            job = JOBS.get(job_id)
            if job:
                job.update({
                    "status": "done",
                    "answer": answer,
                    "finished_at": now_ts(),
                })
    except Exception as exc:
        with JOB_LOCK:
            job = JOBS.get(job_id)
            if job:
                job.update({
                    "status": "error",
                    "error": str(exc)[-4000:] or exc.__class__.__name__,
                    "finished_at": now_ts(),
                })


class Handler(backend.Handler):
    server_version = "AutoAgentControl/0.6.1-chatfix"

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
            if not self.authed():
                self.send_json(401, {"error": "unauthorized"})
                return
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
            payload = {
                "job_id": job_id,
                "status": snapshot["status"],
                "agent": snapshot["agent"],
                "conversation_id": snapshot["conversation_id"],
                "created_at": snapshot["created_at"],
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
        created = now_ts()

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
            }

        EXECUTOR.submit(run_job, job_id, agent, routed, conversation_id, client_ip)
        self.send_json(202, {
            "job_id": job_id,
            "status": "queued",
            "agent": agent,
            "conversation_id": conversation_id,
            "poll_url": f"/api/chat/jobs/{job_id}",
            "retry_after_ms": 800,
        })


if __name__ == "__main__":
    server = backend.ThreadingHTTPServer((backend.HOST, backend.PORT), Handler)
    print(f"[control-center-async] listening on {backend.HOST}:{backend.PORT}; long AI work uses async jobs")
    server.serve_forever()
