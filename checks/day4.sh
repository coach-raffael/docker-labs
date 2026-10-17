#!/usr/bin/env bash
# Day 4, Module 15: acceptance checks for "Harden, scan and publish taskr".
# Expects: Compose project "taskr" started from your hardened copy of broken/day4/compose.yaml,
# taskr 2.2 from your own Dockerfile (non-root UID 10001, base image pinned by digest),
# the registry from Module 14 on 127.0.0.1:5000 with taskr:2.2 pushed and signed, trivy installed,
# an SBOM file taskr.cdx.json in the project directory.
# Run from the repository root:  ./checks/day4.sh
set -u
. "$(dirname "$0")/lib.sh"
PROJECT=taskr
LAB="$(cd "$(dirname "$0")/.." && pwd)"

echo "Part A: hardened"
db="$(compose_container "$PROJECT" db)"
taskr="$(compose_container "$PROJECT" taskr)"
if [ -n "$db" ]; then ok "service db of project $PROJECT is running"; else fail "service db of project $PROJECT is not running"; fi
if [ -n "$taskr" ]; then ok "service taskr of project $PROJECT is running"; else fail "service taskr of project $PROJECT is not running"; fi
[ -n "$db" ] && [ -n "$taskr" ] || summary
workdir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$taskr")"
config="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$taskr")"
IFS=',' read -r -a config_list <<<"$config"
image="$(docker inspect --format '{{.Config.Image}}' "$taskr")"
echo "  project directory: $workdir, taskr image: $image"

user="$(docker inspect --format '{{.Config.User}}' "$taskr")"
if [ "$user" = "10001" ] || [ "$user" = "10001:10001" ]; then ok "taskr runs as UID 10001"; else fail "taskr runs as user '${user:-root}', expected 10001"; fi
check "root filesystem is read-only" test "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$taskr")" = "true"
capdrop="$(docker inspect --format '{{json .HostConfig.CapDrop}}' "$taskr")"
if contains '"ALL"' "$capdrop"; then ok "all capabilities are dropped"; else fail "cap_drop is $capdrop, expected ALL"; fi
secopt="$(docker inspect --format '{{json .HostConfig.SecurityOpt}}' "$taskr")"
if contains 'no-new-privileges' "$secopt"; then ok "no-new-privileges is set"; else fail "security_opt is $secopt, expected no-new-privileges"; fi
memory="$(docker inspect --format '{{.HostConfig.Memory}}' "$taskr")"
if [ "${memory:-0}" -gt 0 ] 2>/dev/null; then ok "memory limit is set ($memory bytes)"; else fail "no memory limit"; fi
dbports="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$db")"
if [ "$dbports" = "null" ] || [ "$dbports" = "{}" ]; then ok "db publishes no port"; else fail "db publishes ports: $dbports"; fi
health="$(http_body http://127.0.0.1:8080/health 2>/dev/null || true)"
if json_has version "2.2.0" "$health" && json_has status ok "$health"; then ok "GET /health reports version 2.2.0"; else fail "GET /health: ${health:-no answer}"; fi

password="$(env_value "$workdir/.env" POSTGRES_PASSWORD)"
if [ -n "$password" ]; then ok ".env holds the password"; else fail "no .env with POSTGRES_PASSWORD in $workdir"; fi
if [ -n "$password" ] && ! grep -qF "$password" "${config_list[@]}" 2>/dev/null; then
  ok "the password is not written in the Compose file"
else
  fail "the Compose file still contains the password, or .env is missing ($config)"
fi
image_env="$(docker image inspect --format '{{json .Config.Env}}' "$image" 2>/dev/null || echo "inspect failed")"
image_history="$(docker history --no-trunc "$image" 2>/dev/null || echo "history failed")"
if [ -n "$password" ] && ! contains "$password" "$image_env" && ! contains "$password" "$image_history" \
   && ! contains "failed" "$image_env"; then
  ok "the password is neither in the image environment nor in its history"
else
  fail "the password appears in docker image inspect or docker history of $image (or .env is missing)"
fi
last_from="$(grep -E '^FROM ' "$LAB/taskr-v2/Dockerfile" 2>/dev/null | tail -n 1)"
if printf '%s' "$last_from" | grep -Eq '@sha256:[0-9a-f]{64}'; then
  ok "the runtime stage of taskr-v2/Dockerfile pins its base image by digest"
else
  fail "the last FROM line of taskr-v2/Dockerfile has no @sha256:<digest> (got: ${last_from:-none})"
fi

echo "Part B: scanned, published, signed"
if command -v trivy >/dev/null 2>&1; then
  if trivy image --quiet --exit-code 1 --severity CRITICAL --ignore-unfixed "$image" >/dev/null 2>&1; then
    ok "trivy finds no fixable CRITICAL vulnerability in $image"
  else
    fail "trivy reports fixable CRITICAL vulnerabilities in $image (or could not scan it)"
  fi
else
  fail "trivy is not installed (Module 14)"
fi
check "SBOM taskr.cdx.json exists in the project directory" test -s "$workdir/taskr.cdx.json"
tags="$(http_body http://127.0.0.1:5000/v2/taskr/tags/list 2>/dev/null || true)"
if contains '"2.2"' "$tags"; then ok "registry 127.0.0.1:5000 holds taskr:2.2"; else fail "registry 127.0.0.1:5000 does not list taskr:2.2 (got: ${tags:-no answer})"; fi
if command -v cosign >/dev/null 2>&1 && [ -f "$workdir/cosign.pub" ]; then
  if cosign verify --key "$workdir/cosign.pub" 127.0.0.1:5000/taskr:2.2 >/dev/null 2>&1; then
    ok "cosign verify succeeds with $workdir/cosign.pub"
  else
    fail "cosign verify --key $workdir/cosign.pub 127.0.0.1:5000/taskr:2.2 failed (Module 14 shows the flags for a registry without Rekor)"
  fi
elif printf '%s' "$tags" | grep -Eq 'sha256-[0-9a-f]{64}\.sig'; then
  ok "a cosign signature is stored next to the image (cosign or cosign.pub not found here, so verify yourself)"
else
  fail "no signature found: sign the image with cosign and keep cosign.pub in the project directory (Module 14)"
fi

summary
