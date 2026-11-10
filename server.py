#!/usr/bin/env python3
"""Minimal local to-do server: serves index.html and a JSON API backed by todos.json.

Usage:
    python3 server.py            # http://localhost:8765
    python3 server.py add "Task text" [Project]
"""
import json
import os
import re
import sys
import tempfile
import uuid
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_FILE = os.path.join(BASE_DIR, "todos.json")
LABELS_FILE = os.path.join(BASE_DIR, "labels.json")
INDEX_FILE = os.path.join(BASE_DIR, "index.html")
PORT = int(os.environ.get("TODO_PORT", "8765"))


STATUSES = ("todo", "doing", "qa", "done")
TRASH_DAYS = 30  # deleted notes stay in the trash at least this long
LOCAL_HOSTS = {"localhost", "127.0.0.1"}
ALLOWED_ORIGINS = {f"http://{host}:{PORT}" for host in LOCAL_HOSTS}
HEX_COLOR = re.compile(r"^#[0-9a-fA-F]{6}$")


def load_todos():
    try:
        with open(DATA_FILE, encoding="utf-8") as f:
            todos = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    cutoff = datetime.now() - timedelta(days=TRASH_DAYS)
    todos = [t for t in todos if not t.get("deleted") or datetime.fromisoformat(t["deleted"]) > cutoff]
    for i, todo in enumerate(todos):
        todo.setdefault("status", "done" if todo.get("done") else "todo")
        todo.setdefault("order", float(i))
    return todos


def save_json(path, data):
    fd, tmp = tempfile.mkstemp(dir=BASE_DIR, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def save_todos(todos):
    save_json(DATA_FILE, todos)


def load_labels():
    """Project name -> note color, e.g. {"Work": "#a8e6ff"}."""
    try:
        with open(LABELS_FILE, encoding="utf-8") as f:
            labels = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    return labels if isinstance(labels, dict) else {}


def new_todo(text, project, status="todo", order=None):
    return {
        "id": uuid.uuid4().hex[:8],
        "text": text.strip(),
        "project": (project or "General").strip(),
        "status": status if status in STATUSES else "todo",
        "done": status == "done",
        "order": order if order is not None else datetime.now().timestamp(),
        "created": datetime.now().isoformat(timespec="seconds"),
    }


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, data):
        self._send(status, json.dumps(data, ensure_ascii=False).encode("utf-8"))

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}")

    def _todo_id(self):
        return self.path.rsplit("/", 1)[-1]

    def _is_local_request(self, writing):
        """Block DNS rebinding (foreign Host) and cross-site writes (foreign Origin or non-JSON body)."""
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        if host not in LOCAL_HOSTS:
            return False
        if not writing:
            return True
        origin = self.headers.get("Origin")
        if origin is not None and origin not in ALLOWED_ORIGINS:
            return False
        # Requiring JSON forces a CORS preflight, which this server never approves for other sites.
        return (self.headers.get("Content-Type") or "").split(";")[0].strip() == "application/json"

    def handle_one_request(self):
        # Wraps every verb: parse the request line first, then reject before dispatching.
        self.raw_requestline = self.rfile.readline(65537)
        if not self.raw_requestline:
            self.close_connection = True
            return
        if not self.parse_request():
            return
        writing = self.command not in ("GET", "HEAD")
        if not self._is_local_request(writing):
            self._json(403, {"error": "forbidden"})
            return
        method = getattr(self, "do_" + self.command, None)
        if method is None:
            self.send_error(501)
            return
        method()
        self.wfile.flush()

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            with open(INDEX_FILE, "rb") as f:
                self._send(200, f.read(), "text/html")
        elif self.path == "/api/todos":
            self._json(200, load_todos())
        elif self.path == "/api/labels":
            self._json(200, load_labels())
        else:
            self._send(404)

    def do_POST(self):
        if self.path != "/api/todos":
            return self._send(404)
        data = self._body()
        if not (data.get("text") or "").strip():
            return self._json(400, {"error": "text is required"})
        todos = load_todos()
        todo = new_todo(data["text"], data.get("project"), data.get("status", "todo"), data.get("order"))
        todos.append(todo)
        save_todos(todos)
        self._json(201, todo)

    def do_PUT(self):
        if self.path != "/api/labels":
            return self._send(404)
        data = self._body()
        if not isinstance(data, dict) or not all(
            isinstance(k, str) and isinstance(v, str) and HEX_COLOR.match(v) for k, v in data.items()
        ):
            return self._json(400, {"error": "labels must map project names to #rrggbb colors"})
        save_json(LABELS_FILE, data)
        self._json(200, data)

    def do_PATCH(self):
        data = self._body()
        todos = load_todos()
        for todo in todos:
            if todo["id"] == self._todo_id():
                # Reordering alone is not a modification; content or column changes are.
                if any(key in data and data[key] != todo.get(key) for key in ("text", "project", "status")):
                    todo["updated"] = datetime.now().isoformat(timespec="seconds")
                for key in ("text", "project", "status", "order"):
                    if key in data:
                        todo[key] = data[key]
                if "deleted" in data and data["deleted"] is None:  # restore from trash
                    todo.pop("deleted", None)
                if "done" in data and "status" not in data:
                    todo["status"] = "done" if data["done"] else "todo"
                todo["done"] = todo["status"] == "done"
                save_todos(todos)
                return self._json(200, todo)
        self._send(404)

    def do_DELETE(self):
        """First delete moves the note to the trash; deleting it from the trash removes it for good."""
        todos = load_todos()
        todo = next((t for t in todos if t["id"] == self._todo_id()), None)
        if todo is None:
            return self._send(404)
        if todo.get("deleted"):
            todos.remove(todo)
        else:
            todo["deleted"] = datetime.now().isoformat(timespec="seconds")
        save_todos(todos)
        self._send(204)

    def log_message(self, *args):
        pass


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "add":
        todos = load_todos()
        todo = new_todo(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
        todos.append(todo)
        save_todos(todos)
        print(f"Added [{todo['project']}] {todo['text']}")
        return
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"To-do UI at http://localhost:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
