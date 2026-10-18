#!/usr/bin/env bash
# Day 1, Module 04: acceptance checks for "Containerize taskr 1.0".
# Expects: image taskr:1.0-lab built from your Dockerfile in taskr-v1, container taskr-lab on host port 8081.
# Run from the repository root:  ./checks/day1.sh
set -u
. "$(dirname "$0")/lib.sh"
LAB="$(cd "$(dirname "$0")/.." && pwd)"

echo "Part A: the image"
check "image taskr:1.0-lab exists" docker image inspect taskr:1.0-lab
check "taskr-v1/.dockerignore exists" test -f "$LAB/taskr-v1/.dockerignore"
cmd0="$(docker image inspect --format '{{index .Config.Cmd 0}}' taskr:1.0-lab 2>/dev/null)"
if [ -n "$cmd0" ] && [ "$cmd0" != "/bin/sh" ]; then
  ok "CMD is in exec form (first element: $cmd0)"
else
  fail "CMD is not in exec form (docker image inspect shows: ${cmd0:-nothing})"
fi

history="$(docker history --format '{{.CreatedBy}}' taskr:1.0-lab 2>/dev/null || true)"
pip_line="$(printf '%s\n' "$history" | grep -nE 'pip3? install' | head -n 1 | cut -d: -f1)"
code_line="$(printf '%s\n' "$history" | grep -n 'COPY' | head -n 1 | cut -d: -f1)"
if [ -n "$pip_line" ] && [ -n "$code_line" ] && [ "$pip_line" -gt "$code_line" ]; then
  ok "docker history shows the dependencies in their own layer before the code"
else
  fail "docker history: pip install should run in a layer before the COPY of the code"
fi

echo "Part B: the service"
if running taskr-lab; then
  ok "container taskr-lab is running"
else
  fail "container taskr-lab is not running"
fi
image="$(docker inspect --format '{{.Config.Image}}' taskr-lab 2>/dev/null || true)"
if [ "$image" = "taskr:1.0-lab" ]; then
  ok "taskr-lab runs your image taskr:1.0-lab"
else
  fail "taskr-lab runs '${image:-nothing}', expected your image taskr:1.0-lab"
fi
ports="$(docker port taskr-lab 8080 2>/dev/null || true)"
if contains ":8081" "$ports"; then
  ok "port 8080 is published on host port 8081"
else
  fail "port 8080 is not published on host port 8081 (docker port shows: ${ports:-nothing})"
fi
env="$(docker inspect --format '{{json .Config.Env}}' taskr-lab 2>/dev/null || true)"
if contains '"LOG_FORMAT=json"' "$env"; then
  ok "LOG_FORMAT=json is set"
else
  fail "LOG_FORMAT=json is not set"
fi
policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' taskr-lab 2>/dev/null || true)"
if [ "$policy" = "unless-stopped" ]; then
  ok "restart policy is unless-stopped"
else
  fail "restart policy is '${policy:-none}', expected unless-stopped"
fi

health="$(http_body http://127.0.0.1:8081/health 2>/dev/null || true)"
if json_has version "1.0.0" "$health"; then
  ok "GET /health reports version 1.0.0"
else
  fail "GET /health on port 8081 did not report version 1.0.0 (got: ${health:-no answer})"
fi
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
  -H 'Content-Type: application/json' -d '{"title":"Day 1 check"}' http://127.0.0.1:8081/tasks)"
if [ "$code" = "201" ]; then
  ok "POST /tasks answers 201"
else
  fail "POST /tasks answered ${code:-nothing}, expected 201"
fi
if docker logs taskr-lab 2>/dev/null | grep -Eq '^\{.*"path": *"/tasks".*\}$'; then
  ok "docker logs shows the request as a JSON line"
else
  fail "docker logs has no JSON line for POST /tasks"
fi

summary
