#!/usr/bin/env bash
# Day 2, Module 08: acceptance checks for "taskr 2.0 with persistent data".
# Expects: network taskr-net, container db (postgres:18, volume taskr-db), container taskr (taskr:2.0)
# published on 127.0.0.1:8080 only, at least three tasks, backup ~/backups/taskr-db.tar.gz,
# restored volume taskr-db-restore.
# Run from the repository root:  ./checks/day2.sh
set -u
. "$(dirname "$0")/lib.sh"

echo "Part A: the system"
check "network taskr-net exists" docker network inspect taskr-net
check "volume taskr-db exists" docker volume inspect taskr-db
for name in db taskr; do
  if running "$name"; then
    ok "container $name is running"
  else
    fail "container $name is not running"
  fi
  nets="$(docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$name" 2>/dev/null || true)"
  if contains "taskr-net" "$nets"; then
    ok "container $name is on taskr-net"
  else
    fail "container $name is not on taskr-net (networks: ${nets:-none})"
  fi
done

image="$(docker inspect --format '{{.Config.Image}}' db 2>/dev/null || true)"
if contains "postgres:18" "$image"; then
  ok "db runs postgres:18"
else
  fail "db runs '${image:-nothing}', expected postgres:18"
fi
image="$(docker inspect --format '{{.Config.Image}}' taskr 2>/dev/null || true)"
if [ "$image" = "taskr:2.0" ]; then
  ok "taskr runs your image taskr:2.0"
else
  fail "taskr runs '${image:-nothing}', expected your image taskr:2.0"
fi
mount="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql"}}{{.Name}}{{end}}{{end}}' db 2>/dev/null || true)"
if [ "$mount" = "taskr-db" ]; then
  ok "volume taskr-db is mounted at /var/lib/postgresql"
else
  fail "no volume taskr-db at /var/lib/postgresql in db (found: ${mount:-nothing})"
fi
dbports="$(docker inspect --format '{{json .HostConfig.PortBindings}}' db 2>/dev/null || true)"
if [ "$dbports" = "null" ] || [ "$dbports" = "{}" ]; then
  ok "db publishes no port"
else
  fail "db publishes ports: $dbports"
fi
bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' taskr 2>/dev/null || true)"
if contains '"HostIp":"127.0.0.1","HostPort":"8080"' "$bindings" && ! contains '"HostIp":"",' "$bindings" && ! contains '"HostIp":"0.0.0.0"' "$bindings"; then
  ok "taskr is published on 127.0.0.1:8080 only"
else
  fail "taskr port bindings: ${bindings:-none}, expected only 127.0.0.1:8080"
fi

health="$(http_body http://127.0.0.1:8080/health 2>/dev/null || true)"
if json_has storage postgresql "$health" && json_has status ok "$health"; then
  ok "GET /health reports storage postgresql"
else
  fail "GET /health: ${health:-no answer}"
fi
tasks="$(http_body http://127.0.0.1:8080/tasks 2>/dev/null || true)"
count="$(printf '%s' "$tasks" | grep -o '"id"' | wc -l | tr -d ' ')"
if [ "${count:-0}" -ge 3 ]; then
  ok "at least three tasks are stored ($count)"
else
  fail "found $count tasks, expected at least 3 (create them, then remove and recreate both containers)"
fi

echo "Backup and restore"
check "backup ~/backups/taskr-db.tar.gz exists" test -s "$HOME/backups/taskr-db.tar.gz"
if docker volume inspect taskr-db-restore >/dev/null 2>&1; then
  ok "volume taskr-db-restore exists"
  if docker run --rm -v taskr-db-restore:/data:ro busybox sh -c 'test -s /data/18/docker/PG_VERSION' >/dev/null 2>&1; then
    ok "taskr-db-restore contains a PostgreSQL 18 data directory"
  else
    fail "taskr-db-restore has no 18/docker/PG_VERSION file"
  fi
else
  fail "volume taskr-db-restore does not exist"
fi

summary
