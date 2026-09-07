#!/usr/bin/env python3
"""Auto Agent UI shell v0.6.0.

This module reuses the security/session/router implementation from
control_center_v2.py and replaces only the presentation template. Keeping the
UI separate makes future redesigns independent from authentication logic.
"""
from pathlib import Path
import importlib.util
import os

APP_DIR = Path(os.environ.get("AUTO_AGENT_APP_DIR", Path.home() / ".local/share/auto_agent"))
BASE = APP_DIR / "control_center_v2.py"
UI = APP_DIR / "control_center_ui.html"

if not BASE.is_file():
    raise SystemExit(f"Missing backend module: {BASE}")
if not UI.is_file():
    raise SystemExit(f"Missing UI template: {UI}")

spec = importlib.util.spec_from_file_location("auto_agent_control_backend", BASE)
backend = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(backend)

ui = UI.read_text(encoding="utf-8")
required = ('id="messages"', 'id="prompt"', 'id="mode"', 'id="send"', '__CENTER_PUBLIC_HOST__')
missing = [marker for marker in required if marker not in ui]
if missing:
    raise SystemExit(f"UI template missing required markers: {missing}")

backend.APP_HTML = ui
backend.Handler.server_version = "AutoAgentControl/0.6.0"

if __name__ == "__main__":
    server = backend.ThreadingHTTPServer((backend.HOST, backend.PORT), backend.Handler)
    print(f"[control-center-ui] listening on {backend.HOST}:{backend.PORT} with UI v0.6.0")
    server.serve_forever()
