"""taskr 2.0: a small task API, the example app of the IT made simple container courses.

Settings come from environment variables, every request is logged to stdout, and the
tasks live in PostgreSQL when DATABASE_URL or DATABASE_URL_FILE is set, in memory otherwise.
Start it with gunicorn (gunicorn.conf.py is next to this file): gunicorn app:app
"""

import json
import logging
import os
import socket
import sys
import threading
import time
from datetime import datetime, timezone

import psycopg
from flask import Flask, g, jsonify, request
from psycopg.rows import dict_row
from werkzeug.exceptions import HTTPException

VERSION = os.environ.get("TASKR_VERSION", "2.0.0")
PORT = int(os.environ.get("PORT", "8080"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
LOG_FORMAT = os.environ.get("LOG_FORMAT", "text").lower()
PRIORITIES = ("low", "normal", "high")
STATUSES = ("open", "in_progress", "done")
TITLE_MAX = 200
CONNECT_TIMEOUT = 3
LOCK_KEY = 20260101  # advisory lock so that replicas starting at once create the table only once

CREATE_TABLE = """
CREATE TABLE IF NOT EXISTS tasks (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title       text NOT NULL,
    priority    text NOT NULL DEFAULT 'normal',
    status      text NOT NULL DEFAULT 'open',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
)
"""


# ---------------------------------------------------------------- logging

class JsonFormatter(logging.Formatter):
    """One JSON object per line. Extra fields from log calls are included."""

    FIELDS = ("method", "path", "status", "duration_ms", "remote")

    def format(self, record):
        line = {
            "time": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for field in self.FIELDS:
            if hasattr(record, field):
                line[field] = getattr(record, field)
        return json.dumps(line)


def setup_logging():
    handler = logging.StreamHandler(sys.stdout)
    if LOG_FORMAT == "json":
        handler.setFormatter(JsonFormatter())
    else:
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(LOG_LEVEL if LOG_LEVEL in ("DEBUG", "INFO", "WARNING", "ERROR") else "INFO")


setup_logging()
log = logging.getLogger("taskr")


def fail(message):
    """Stop the process with a clear message and exit code 1 (startup errors only)."""
    log.error("startup failed: %s", message)
    sys.exit(1)


def one_line(error):
    return " ".join(str(error).split())


# ---------------------------------------------------------------- storage

def now():
    return datetime.now(timezone.utc)


def as_json(task):
    task = dict(task)
    for key in ("created_at", "updated_at"):
        if isinstance(task[key], datetime):
            task[key] = task[key].isoformat(timespec="seconds")
    return task


class MemoryStorage:
    name = "memory"

    def __init__(self):
        self._tasks = []
        self._next_id = 1
        self._lock = threading.Lock()

    def ping(self):
        return True

    def list(self, status=None):
        with self._lock:
            tasks = [t for t in self._tasks if status is None or t["status"] == status]
        return [as_json(t) for t in reversed(tasks)]

    def create(self, title, priority):
        with self._lock:
            stamp = now()
            task = {"id": self._next_id, "title": title, "priority": priority,
                    "status": "open", "created_at": stamp, "updated_at": stamp}
            self._next_id += 1
            self._tasks.append(task)
        return as_json(task)

    def update_status(self, task_id, status):
        with self._lock:
            for task in self._tasks:
                if task["id"] == task_id:
                    task["status"] = status
                    task["updated_at"] = now()
                    return as_json(task)
        return None

    def counts(self):
        with self._lock:
            return {s: sum(1 for t in self._tasks if t["status"] == s) for s in STATUSES}


class PostgresStorage:
    name = "postgresql"

    def __init__(self, url):
        self.url = url

    def connect(self):
        return psycopg.connect(self.url, connect_timeout=CONNECT_TIMEOUT,
                               autocommit=True, row_factory=dict_row)

    def init(self):
        """Create the table. Called once at startup; the lock makes it safe for many replicas."""
        with self.connect() as conn, conn.transaction():
            conn.execute("SELECT pg_advisory_xact_lock(%s)", (LOCK_KEY,))
            conn.execute(CREATE_TABLE)

    def ping(self):
        try:
            with self.connect() as conn:
                conn.execute("SELECT 1")
            return True
        except psycopg.OperationalError:
            return False

    def list(self, status=None):
        with self.connect() as conn:
            if status is None:
                rows = conn.execute("SELECT * FROM tasks ORDER BY id DESC").fetchall()
            else:
                rows = conn.execute("SELECT * FROM tasks WHERE status = %s ORDER BY id DESC",
                                    (status,)).fetchall()
        return [as_json(r) for r in rows]

    def create(self, title, priority):
        with self.connect() as conn:
            row = conn.execute(
                "INSERT INTO tasks (title, priority) VALUES (%s, %s) RETURNING *",
                (title, priority)).fetchone()
        return as_json(row)

    def update_status(self, task_id, status):
        with self.connect() as conn:
            row = conn.execute(
                "UPDATE tasks SET status = %s, updated_at = now() WHERE id = %s RETURNING *",
                (status, task_id)).fetchone()
        return as_json(row) if row else None

    def counts(self):
        with self.connect() as conn:
            rows = conn.execute("SELECT status, count(*) AS n FROM tasks GROUP BY status").fetchall()
        result = {s: 0 for s in STATUSES}
        for row in rows:
            result[row["status"]] = row["n"]
        return result


def load_database_url():
    """Return the database URL from DATABASE_URL or DATABASE_URL_FILE, or None for memory."""
    url = os.environ.get("DATABASE_URL", "").strip()
    path = os.environ.get("DATABASE_URL_FILE", "").strip()
    if url and path:
        fail("set either DATABASE_URL or DATABASE_URL_FILE, not both")
    if path:
        try:
            with open(path, encoding="utf-8") as f:
                url = f.read().strip()
        except OSError as e:
            fail(f"cannot read DATABASE_URL_FILE {path}: {e.strerror}")
        if not url:
            fail(f"DATABASE_URL_FILE {path} is empty")
    return url or None


def make_storage():
    url = load_database_url()
    if url is None:
        log.info("storage: memory (set DATABASE_URL for PostgreSQL)")
        return MemoryStorage()
    storage = PostgresStorage(url)
    try:
        storage.init()
    except psycopg.OperationalError as e:
        fail(f"database unreachable: {one_line(e)}")
    except psycopg.Error as e:
        fail(f"database error: {one_line(e)}")
    log.info("storage: postgresql, table tasks ready")
    return storage


storage = make_storage()

# ---------------------------------------------------------------- web app

app = Flask(__name__)
app.json.sort_keys = False


def error(status, message):
    return jsonify(error=message), status


@app.errorhandler(HTTPException)
def http_error(e):
    response = jsonify(error=e.name.lower())
    response.status_code = e.code
    for key, value in e.get_headers():  # keeps for example the Allow header of a 405
        if key.lower() != "content-type":
            response.headers[key] = value
    return response


@app.before_request
def start_timer():
    g.started = time.perf_counter()


@app.after_request
def log_request(response):
    duration = round((time.perf_counter() - g.started) * 1000, 1)
    log.info("%s %s %s %sms", request.method, request.path, response.status_code, duration,
             extra={"method": request.method, "path": request.path,
                    "status": response.status_code, "duration_ms": duration,
                    "remote": request.remote_addr})
    return response


@app.get("/health")
def health():
    body = {"status": "ok", "version": VERSION, "storage": storage.name}
    if not storage.ping():
        body.update(status="error", detail="database unreachable")
        return jsonify(body), 503
    return jsonify(body)


@app.get("/tasks")
def list_tasks():
    status = request.args.get("status")
    if status is not None and status not in STATUSES:
        return error(400, f"unknown status '{status}', use one of: {', '.join(STATUSES)}")
    return jsonify(storage.list(status))


@app.post("/tasks")
def create_task():
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return error(400, "send a JSON object, for example {\"title\": \"Write the Dockerfile\"}")
    title = body.get("title")
    title = title.strip() if isinstance(title, str) else ""
    if not title:
        return error(400, "title is required")
    if len(title) > TITLE_MAX:
        return error(400, f"title is longer than {TITLE_MAX} characters")
    priority = body.get("priority", "normal")
    if priority not in PRIORITIES:
        return error(400, f"unknown priority '{priority}', use one of: {', '.join(PRIORITIES)}")
    task = storage.create(title, priority)
    return jsonify(task), 201, {"Location": f"/tasks/{task['id']}"}


@app.patch("/tasks/<int:task_id>")
def update_task(task_id):
    body = request.get_json(silent=True)
    status = body.get("status") if isinstance(body, dict) else None
    if status not in STATUSES:
        return error(400, f"status is required, use one of: {', '.join(STATUSES)}")
    task = storage.update_status(task_id, status)
    if task is None:
        return error(404, f"task {task_id} not found")
    return jsonify(task)


@app.get("/stats")
def stats():
    body = storage.counts()
    body.update(storage=storage.name, hostname=socket.gethostname())
    return jsonify(body)


if __name__ == "__main__":
    # Development only. The containers run gunicorn, see gunicorn.conf.py.
    app.run(host="0.0.0.0", port=PORT)
