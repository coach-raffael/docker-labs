#!/usr/bin/env bash
# Shared helpers for the acceptance checks day1.sh to day5.sh. Not meant to be run directly.
# Every check prints "ok" or "FAIL" with a short reason; the script ends with PASS or FAIL.

FAILED=0
PASSED=0

ok() {
  PASSED=$((PASSED + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  printf '  FAIL  %s\n' "$1"
}

# check "description" command...   -> ok if the command succeeds (output hidden)
check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$description"
  else
    fail "$description"
  fi
}

# running NAME  -> true if a container with that exact name is running
running() {
  [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

# http_body URL  -> prints the response body, fails on connection errors and non-2xx codes
http_body() {
  curl -fsS --max-time 5 "$@"
}

# contains STRING TEXT  -> true if TEXT contains STRING
contains() {
  case "$2" in *"$1"*) return 0 ;; esac
  return 1
}

# json_has KEY VALUE JSON -> true if the JSON text contains "KEY":"VALUE" (spaces allowed)
json_has() {
  printf '%s' "$3" | grep -Eq "\"$1\"[[:space:]]*:[[:space:]]*\"?$2\"?"
}

# compose_container PROJECT SERVICE -> prints the container id of that Compose service
compose_container() {
  docker ps -q \
    --filter "label=com.docker.compose.project=$1" \
    --filter "label=com.docker.compose.service=$2" | head -n 1
}

# env_value FILE KEY -> prints the value of KEY=value from an .env file (quotes removed)
env_value() {
  sed -n "s/^[[:space:]]*$2=//p" "$1" 2>/dev/null | head -n 1 | tr -d "\"'"
}

summary() {
  echo
  if [ "$FAILED" -eq 0 ]; then
    echo "PASS ($PASSED checks)"
    exit 0
  fi
  echo "FAIL ($FAILED of $((PASSED + FAILED)) checks failed)"
  exit 1
}
