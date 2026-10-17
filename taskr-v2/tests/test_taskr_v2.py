import json
import subprocess
import sys

import psycopg
import pytest


# ---------------------------------------------------------------- in-memory API

def test_health_reports_memory_storage_and_version(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.get_json() == {"status": "ok", "version": "2.0.0", "storage": "memory"}


def test_version_comes_from_environment(load_app):
    module = load_app(TASKR_VERSION="2.1.0")
    assert module.app.test_client().get("/health").get_json()["version"] == "2.1.0"


def test_create_list_and_update(client):
    r = client.post("/tasks", json={"title": "Write the Dockerfile", "priority": "high"})
    assert r.status_code == 201
    task = r.get_json()
    assert task["id"] == 1
    assert task["status"] == "open"
    assert task["priority"] == "high"
    assert r.headers["Location"] == "/tasks/1"

    client.post("/tasks", json={"title": "Build the image"})
    tasks = client.get("/tasks").get_json()
    assert [t["title"] for t in tasks] == ["Build the image", "Write the Dockerfile"]
    assert tasks[0]["priority"] == "normal"

    r = client.patch("/tasks/1", json={"status": "done"})
    assert r.status_code == 200
    assert r.get_json()["status"] == "done"
    assert client.get("/tasks?status=done").get_json()[0]["id"] == 1
    assert client.get("/tasks?status=open").get_json()[0]["id"] == 2


def test_validation_errors_are_json(client):
    assert client.post("/tasks", data="not json").status_code == 400
    assert client.post("/tasks", json={}).get_json() == {"error": "title is required"}
    assert client.post("/tasks", json={"title": "x" * 201}).status_code == 400
    r = client.post("/tasks", json={"title": "ok", "priority": "urgent"})
    assert r.status_code == 400 and "priority" in r.get_json()["error"]
    r = client.get("/tasks?status=closed")
    assert r.status_code == 400 and "status" in r.get_json()["error"]
    assert client.patch("/tasks/1", json={"status": "later"}).status_code == 400
    r = client.patch("/tasks/99", json={"status": "done"})
    assert r.status_code == 404 and r.get_json() == {"error": "task 99 not found"}
    r = client.get("/nothing")
    assert r.status_code == 404 and r.get_json() == {"error": "not found"}


def test_stats_count_per_status(client):
    for title in ("a", "b", "c"):
        client.post("/tasks", json={"title": title})
    client.patch("/tasks/1", json={"status": "done"})
    client.patch("/tasks/2", json={"status": "in_progress"})
    body = client.get("/stats").get_json()
    assert body["open"] == 1 and body["in_progress"] == 1 and body["done"] == 1
    assert body["storage"] == "memory"
    assert body["hostname"]


def test_json_log_line_per_request(load_app, capsys):
    module = load_app(LOG_FORMAT="json")
    module.app.test_client().get("/health")
    lines = [l for l in capsys.readouterr().out.splitlines() if '"path": "/health"' in l]
    assert lines, "expected one JSON log line for the request"
    record = json.loads(lines[-1])
    assert record["method"] == "GET" and record["status"] == 200
    assert "duration_ms" in record


# ---------------------------------------------------------------- startup rules (A10)

def test_database_url_file_is_read(load_app, tmp_path, capsys):
    secret = tmp_path / "db_url"
    secret.write_text("postgresql://taskr:x@127.0.0.1:1/taskr\n")
    with pytest.raises(SystemExit) as stop:
        load_app(DATABASE_URL_FILE=str(secret))
    # the file was read: the process tried the database there and stopped because nothing listens
    assert stop.value.code == 1
    assert "database unreachable" in capsys.readouterr().out


def test_missing_database_url_file_stops_with_exit_code_1(load_app, capsys):
    with pytest.raises(SystemExit) as stop:
        load_app(DATABASE_URL_FILE="/run/secrets/does-not-exist")
    assert stop.value.code == 1
    assert "cannot read DATABASE_URL_FILE" in capsys.readouterr().out


def test_both_url_variables_set_stops_with_exit_code_1(load_app, capsys):
    with pytest.raises(SystemExit) as stop:
        load_app(DATABASE_URL="postgresql://a@b/c", DATABASE_URL_FILE="/x")
    assert stop.value.code == 1
    assert "not both" in capsys.readouterr().out


def test_unreachable_database_stops_with_exit_code_1(load_app, capsys):
    with pytest.raises(SystemExit) as stop:
        load_app(DATABASE_URL="postgresql://taskr:x@127.0.0.1:1/taskr")
    assert stop.value.code == 1
    out = capsys.readouterr().out
    assert "startup failed: database unreachable" in out
    assert "\n" not in out.strip().splitlines()[-1]  # the cause is on the same line


# ---------------------------------------------------------------- PostgreSQL (TEST_DATABASE_URL)

@pytest.fixture
def pg_client(load_app, test_database_url):
    with psycopg.connect(test_database_url, autocommit=True) as conn:
        conn.execute("DROP TABLE IF EXISTS tasks")
    module = load_app(DATABASE_URL=test_database_url)
    return module.app.test_client()


def test_postgres_health_and_crud(pg_client):
    assert pg_client.get("/health").get_json() == {"status": "ok", "version": "2.0.0",
                                                   "storage": "postgresql"}
    r = pg_client.post("/tasks", json={"title": "Persist me", "priority": "low"})
    assert r.status_code == 201
    task_id = r.get_json()["id"]
    assert pg_client.patch(f"/tasks/{task_id}", json={"status": "in_progress"}).status_code == 200
    tasks = pg_client.get("/tasks?status=in_progress").get_json()
    assert tasks[0]["id"] == task_id and tasks[0]["created_at"].endswith("+00:00")
    assert pg_client.patch("/tasks/424242", json={"status": "done"}).status_code == 404
    stats = pg_client.get("/stats").get_json()
    assert stats["in_progress"] == 1 and stats["storage"] == "postgresql"


def test_postgres_data_survives_a_restart(load_app, test_database_url, pg_client):
    pg_client.post("/tasks", json={"title": "Survivor"})
    restarted = load_app(DATABASE_URL=test_database_url).app.test_client()
    assert [t["title"] for t in restarted.get("/tasks").get_json()] == ["Survivor"]


def test_postgres_health_is_503_when_database_goes_away(load_app, test_database_url, pg_client):
    module = load_app(DATABASE_URL=test_database_url)
    module.storage.url = "postgresql://taskr:x@127.0.0.1:1/taskr"  # simulate a lost database
    r = module.app.test_client().get("/health")
    assert r.status_code == 503
    assert r.get_json()["detail"] == "database unreachable"


def test_postgres_replicas_can_start_at_the_same_time(test_database_url, app_file):
    """Five processes import the app at once against a database without the table."""
    with psycopg.connect(test_database_url, autocommit=True) as conn:
        conn.execute("DROP TABLE IF EXISTS tasks")
    env = {"DATABASE_URL": test_database_url, "PATH": "/usr/bin:/bin"}
    procs = [subprocess.Popen([sys.executable, "-c", "import app"], cwd=app_file.parent, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
             for _ in range(5)]
    results = [(p.wait(timeout=60), p.stdout.read().decode()) for p in procs]
    assert all(code == 0 for code, _ in results), results
