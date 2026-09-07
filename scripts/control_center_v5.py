#!/usr/bin/env python3
"""Auto Agent Control Center v5: persistent chat history + raw agent pass-through.

This wrapper builds on the runtime-aware async control path in control_center_v4.
It intentionally does NOT run a second LLM pass to summarize, rewrite, translate,
or otherwise polish Hermes/OpenClaw responses. Agent output is stored and returned
verbatim; presentation-only Markdown rendering happens in the browser.
"""
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import importlib.util
import json
import os
import re
import secrets
import sqlite3
import threading
import time

APP_DIR = Path(os.environ.get("AUTO_AGENT_APP_DIR", Path.home() / ".local/share/auto_agent"))
V4 = APP_DIR / "control_center_v4.py"
POLISH_JS = APP_DIR / "control_center_polish.js"
DB_PATH = Path(os.environ.get("AUTO_AGENT_HISTORY_DB", APP_DIR / "chat_history.sqlite3"))

for required in (V4, POLISH_JS):
    if not required.is_file():
        raise SystemExit(f"Missing Control Center v5 component: {required}")

spec = importlib.util.spec_from_file_location("auto_agent_control_v4", V4)
v4 = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(v4)

POLISH_ASSET_PATH = "/_auto_agent_polish.js"
POLISH_JS_BYTES = POLISH_JS.read_bytes()
if "</body>" not in v4.backend.APP_HTML:
    raise SystemExit("Control Center UI has no </body> marker")
v4.backend.APP_HTML = v4.backend.APP_HTML.replace(
    "</body>",
    f'<script src="{POLISH_ASSET_PATH}?v=062-history-markdown"></script>\n</body>',
    1,
)

DB_LOCK = threading.Lock()
CONV_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
MAX_HISTORY_CONTENT = int(os.environ.get("AUTO_AGENT_HISTORY_MAX_MESSAGE_BYTES", str(1024 * 1024)))
MAX_HISTORY_ITEMS = int(os.environ.get("AUTO_AGENT_HISTORY_MAX_CONVERSATIONS", "500"))


def db_connect():
    conn = sqlite3.connect(str(DB_PATH), timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn


def init_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(DB_PATH.parent, 0o700)
    except OSError:
        pass
    with DB_LOCK, db_connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                conversation_id TEXT NOT NULL,
                role TEXT NOT NULL,
                agent TEXT NOT NULL DEFAULT '',
                content TEXT NOT NULL,
                created_at REAL NOT NULL,
                FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_messages_conversation
                ON messages(conversation_id, id);
            CREATE INDEX IF NOT EXISTS idx_conversations_updated
                ON conversations(updated_at DESC);
            """
        )
    try:
        os.chmod(DB_PATH, 0o600)
    except OSError:
        pass


def valid_conversation_id(value):
    value = str(value or "").strip()
    return value if CONV_ID_RE.fullmatch(value) else ""


def title_from_message(content):
    line = " ".join(str(content).strip().split())
    if len(line) > 72:
        line = line[:69].rstrip() + "…"
    return line or "New chat"


def history_append(conversation_id, role, agent, content, created_at=None):
    conversation_id = valid_conversation_id(conversation_id)
    if not conversation_id:
        raise ValueError("invalid conversation id")
    role = str(role or "").lower()
    if role not in {"user", "assistant", "error"}:
        raise ValueError("invalid history role")
    agent = str(agent or "")[:32]
    content = str(content or "")
    if len(content.encode("utf-8")) > MAX_HISTORY_CONTENT:
        content = content.encode("utf-8")[:MAX_HISTORY_CONTENT].decode("utf-8", errors="ignore")
    now = float(created_at or time.time())
    first_title = title_from_message(content) if role == "user" else ""

    with DB_LOCK, db_connect() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO conversations(id,title,created_at,updated_at) VALUES(?,?,?,?)",
            (conversation_id, first_title, now, now),
        )
        if role == "user":
            conn.execute(
                "UPDATE conversations SET title=CASE WHEN title='' THEN ? ELSE title END, updated_at=? WHERE id=?",
                (first_title, now, conversation_id),
            )
        else:
            conn.execute("UPDATE conversations SET updated_at=? WHERE id=?", (now, conversation_id))
        conn.execute(
            "INSERT INTO messages(conversation_id,role,agent,content,created_at) VALUES(?,?,?,?,?)",
            (conversation_id, role, agent, content, now),
        )
        # Bound only the number of completed conversation records retained.
        # This never interrupts an active agent run.
        rows = conn.execute(
            "SELECT id FROM conversations ORDER BY updated_at DESC LIMIT -1 OFFSET ?",
            (MAX_HISTORY_ITEMS,),
        ).fetchall()
        for row in rows:
            conn.execute("DELETE FROM conversations WHERE id=?", (row["id"],))


def history_list(limit=30):
    limit = max(1, min(int(limit), 100))
    with DB_LOCK, db_connect() as conn:
        rows = conn.execute(
            """
            SELECT c.id, c.title, c.created_at, c.updated_at,
                   (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id) AS message_count,
                   (SELECT agent FROM messages m WHERE m.conversation_id=c.id AND m.role IN ('assistant','error') ORDER BY m.id DESC LIMIT 1) AS last_agent
            FROM conversations c
            ORDER BY c.updated_at DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
    return [dict(row) for row in rows]


def history_get(conversation_id):
    conversation_id = valid_conversation_id(conversation_id)
    if not conversation_id:
        return None
    with DB_LOCK, db_connect() as conn:
        conv = conn.execute(
            "SELECT id,title,created_at,updated_at FROM conversations WHERE id=?",
            (conversation_id,),
        ).fetchone()
        if not conv:
            return None
        messages = conn.execute(
            "SELECT id,role,agent,content,created_at FROM messages WHERE conversation_id=? ORDER BY id",
            (conversation_id,),
        ).fetchall()
    return {"conversation": dict(conv), "messages": [dict(row) for row in messages]}


def history_delete(conversation_id):
    conversation_id = valid_conversation_id(conversation_id)
    if not conversation_id:
        return False
    with DB_LOCK, db_connect() as conn:
        cur = conn.execute("DELETE FROM conversations WHERE id=?", (conversation_id,))
        return cur.rowcount > 0


def run_job_persistent(job_id, agent, routed_message, conversation_id, client_ip):
    with v4.JOB_LOCK:
        job = v4.JOBS.get(job_id)
        if not job:
            return
        job["status"] = "running"
        job["started_at"] = v4.now_ts()
        policy = dict(job["runtime_policy"])

    try:
        if agent == "openclaw":
            answer = v4.run_openclaw(routed_message, conversation_id, client_ip, policy)
        else:
            answer = v4.run_hermes(routed_message, policy)
        # Store exactly what the agent returned. No rewrite/summarization pass.
        history_append(conversation_id, "assistant", agent, answer)
        with v4.JOB_LOCK:
            job = v4.JOBS.get(job_id)
            if job:
                job.update({"status": "done", "answer": answer, "finished_at": v4.now_ts()})
    except Exception as exc:
        detail = str(exc)[-4000:] or exc.__class__.__name__
        try:
            history_append(conversation_id, "error", agent, detail)
        except Exception:
            pass
        with v4.JOB_LOCK:
            job = v4.JOBS.get(job_id)
            if job:
                job.update({"status": "error", "error": detail, "finished_at": v4.now_ts()})


class Handler(v4.Handler):
    server_version = "AutoAgentControl/0.6.2-history-markdown"

    def send_polish_js(self):
        data = POLISH_JS_BYTES
        self.send_response(200)
        self.send_header("Content-Type", "application/javascript; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def read_json_body(self, limit=1024 * 1024):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length < 0 or length > limit:
            raise ValueError("request too large")
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == POLISH_ASSET_PATH:
            self.send_polish_js()
            return
        if path == "/api/history":
            if not self.authed():
                self.send_json(401, {"error": "unauthorized"})
                return
            params = parse_qs(parsed.query)
            try:
                limit = int((params.get("limit") or [30])[0])
            except Exception:
                limit = 30
            self.send_json(200, {"conversations": history_list(limit)})
            return
        prefix = "/api/history/"
        if path.startswith(prefix):
            if not self.authed():
                self.send_json(401, {"error": "unauthorized"})
                return
            conversation_id = path[len(prefix):]
            payload = history_get(conversation_id)
            if not payload:
                self.send_json(404, {"error": "history_not_found"})
                return
            self.send_json(200, payload)
            return
        super().do_GET()

    def do_DELETE(self):
        parsed = urlparse(self.path)
        prefix = "/api/history/"
        if parsed.path.startswith(prefix):
            if not self.authed():
                self.send_json(401, {"error": "unauthorized"})
                return
            ok = history_delete(parsed.path[len(prefix):])
            self.send_json(200 if ok else 404, {"deleted": ok})
            return
        self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/api/chat":
            super().do_POST()
            return
        if not self.authed():
            self.send_json(401, {"error": "unauthorized"})
            return

        try:
            payload = self.read_json_body()
            message = str(payload.get("message", "")).strip()
            mode = str(payload.get("mode", "auto"))
            conversation_id = valid_conversation_id(payload.get("conversation_id")) or secrets.token_hex(16)
            if not message:
                raise ValueError("message is required")
            agent, routed = v4.backend.route_message(mode, message)
            if not routed:
                raise ValueError("message is empty after agent routing prefix")
        except Exception as exc:
            self.send_json(400, {"error": str(exc)[-1000:]})
            return

        client_ip = self.real_client_ip()
        job_id = secrets.token_urlsafe(24)
        poll_token = secrets.token_urlsafe(32)
        created = v4.now_ts()
        runtime_policy = v4.resolve_runtime_policy(agent)

        with v4.JOB_LOCK:
            v4.cleanup_jobs_locked(created)
            if v4.active_jobs_locked() >= v4.MAX_ACTIVE_JOBS:
                self.send_json(429, {
                    "error": "too_many_active_jobs",
                    "message": "Auto Agent is already processing the maximum number of concurrent requests.",
                    "retry_after_ms": 3000,
                })
                return
            # Persist the user's original message, not the routed/stripped form.
            history_append(conversation_id, "user", "", message, created_at=created)
            v4.JOBS[job_id] = {
                "status": "queued",
                "agent": agent,
                "conversation_id": conversation_id,
                "created_at": created,
                "runtime_policy": runtime_policy,
                "poll_token_hash": v4.hash_poll_token(poll_token),
            }

        v4.EXECUTOR.submit(run_job_persistent, job_id, agent, routed, conversation_id, client_ip)
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
    init_db()
    hermes_policy = v4.resolve_runtime_policy("hermes", force=True)
    openclaw_policy = v4.resolve_runtime_policy("openclaw", force=True)
    print(f"[control-center-v5] history DB: {DB_PATH}")
    print("[control-center-v5] agent output policy: verbatim pass-through; Markdown is presentation-only")
    print(
        "[control-center-v5] runtime policies: "
        f"Hermes hard={hermes_policy.get('hard_limit_seconds') or 'unlimited'}s; "
        f"OpenClaw hard={openclaw_policy.get('hard_limit_seconds') or 'unlimited'}s"
    )
    server = v4.backend.ThreadingHTTPServer((v4.backend.HOST, v4.backend.PORT), Handler)
    server.serve_forever()
