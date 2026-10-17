#!/usr/bin/env bash
# Day 3, Module 12: acceptance checks for "Ship the taskr stack with Compose".
# Expects: Compose project "taskr" (services db and taskr) started from your repaired copy of
# broken/day3/compose.yaml, taskr built from your own multi-stage Dockerfile with HEALTHCHECK,
# db with a healthcheck, taskr waiting for a healthy db, taskr on 127.0.0.1:8080 only,
# the password in .env, .env listed in .gitignore.
# Run from the repository root:  ./checks/day3.sh
set -u
. "$(dirname "$0")/lib.sh"
PROJECT=taskr

echo "Part A: the repaired stack"
db="$(compose_container "$PROJECT" db)"
taskr="$(compose_container "$PROJECT" taskr)"
if [ -n "$db" ]; then ok "service db of project $PROJECT is running"; else fail "service db of project $PROJECT is not running"; fi
if [ -n "$taskr" ]; then ok "service taskr of project $PROJECT is running"; else fail "service taskr of project $PROJECT is not running"; fi
[ -n "$db" ] && [ -n "$taskr" ] || summary

workdir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$taskr")"
config="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$taskr")"
echo "  project directory: $workdir"
files=()
IFS=',' read -r -a config_list <<<"$config"
for f in "${config_list[@]}"; do files+=(-f "$f"); done
check "docker compose config has no errors" docker compose --project-directory "$workdir" "${files[@]}" config
mount="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql"}}{{.Type}}{{end}}{{end}}' "$db")"
if [ "$mount" = "volume" ]; then
  ok "db keeps its data in a named volume at /var/lib/postgresql"
else
  fail "db has no named volume at /var/lib/postgresql (PostgreSQL 18 moved away from /var/lib/postgresql/data)"
fi
dbports="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$db")"
if [ "$dbports" = "null" ] || [ "$dbports" = "{}" ]; then
  ok "db publishes no port"
else
  fail "db publishes ports: $dbports"
fi
bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$taskr")"
if contains '"HostIp":"127.0.0.1","HostPort":"8080"' "$bindings" && ! contains '"HostIp":"",' "$bindings" && ! contains '"HostIp":"0.0.0.0"' "$bindings"; then
  ok "taskr is published on 127.0.0.1:8080 only"
else
  fail "taskr port bindings: $bindings, expected only 127.0.0.1:8080"
fi
health="$(http_body http://127.0.0.1:8080/health 2>/dev/null || true)"
if json_has storage postgresql "$health" && json_has status ok "$health"; then
  ok "GET /health reports storage postgresql (so DATABASE_URL points to the db service)"
else
  fail "GET /health: ${health:-no answer}"
fi

echo "Part B: reliability"
dbhealth="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$db")"
if [ "$dbhealth" = "healthy" ]; then ok "db has a healthcheck and is healthy"; else fail "db healthcheck status: ${dbhealth:-none}"; fi
taskrhealth="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$taskr")"
if [ "$taskrhealth" = "healthy" ]; then ok "taskr image has a HEALTHCHECK and is healthy"; else fail "taskr healthcheck status: ${taskrhealth:-none}"; fi
depends="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.depends_on"}}' "$taskr")"
if contains "db:service_healthy" "$depends"; then
  ok "taskr waits for a healthy db (depends_on condition service_healthy)"
else
  fail "taskr does not wait for a healthy db (depends_on label: ${depends:-none})"
fi
password="$(env_value "$workdir/.env" POSTGRES_PASSWORD)"
if [ -n "$password" ]; then
  ok ".env with POSTGRES_PASSWORD exists in the project directory"
else
  fail "no .env with POSTGRES_PASSWORD in $workdir"
fi
if [ -n "$password" ] && ! grep -qF "$password" "${config_list[@]}" 2>/dev/null; then
  ok "the password is not written in the Compose file"
else
  fail "the Compose file still contains the password, or .env is missing ($config)"
fi
if git -C "$workdir" check-ignore -q .env 2>/dev/null; then
  ok "git ignores .env in the project directory"
else
  fail "git does not ignore $workdir/.env (add it to a .gitignore)"
fi

summary
