import json


def test_health_reports_memory_storage_and_version(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.get_json() == {"status": "ok", "version": "1.0.0", "storage": "memory"}


def test_version_comes_from_environment(load_app):
    module = load_app(TASKR_VERSION="1.0.1")
    assert module.app.test_client().get("/health").get_json()["version"] == "1.0.1"


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


def test_tasks_do_not_survive_a_restart(load_app):
    first = load_app().app.test_client()
    first.post("/tasks", json={"title": "Lost on restart"})
    restarted = load_app().app.test_client()
    assert restarted.get("/tasks").get_json() == []


def test_json_log_line_per_request(load_app, capsys):
    module = load_app(LOG_FORMAT="json")
    module.app.test_client().get("/health")
    lines = [l for l in capsys.readouterr().out.splitlines() if '"path": "/health"' in l]
    assert lines, "expected one JSON log line for the request"
    record = json.loads(lines[-1])
    assert record["method"] == "GET" and record["status"] == 200
    assert "duration_ms" in record
