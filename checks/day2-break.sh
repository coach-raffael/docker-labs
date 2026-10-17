#!/usr/bin/env bash
# Day 2, Module 08, Part B: starts taskr 2.0 with a planted fault.
# Find the cause with the method from Module 07 (state, logs, inspect, events, exec),
# explain it in two sentences, then fix it. Remove the container when you are done:
#   docker rm -f taskr-planted
# Expects: your image taskr:2.0, the network taskr-net and the container db from Part A
# (PostgreSQL user taskr, password taskr-lab, database taskr, as in Module 06).
# Diagnose first, read the docker run command below afterwards.
set -euo pipefail

docker image inspect taskr:2.0 >/dev/null 2>&1 || { echo "build taskr:2.0 first (Module 06)"; exit 1; }
docker network inspect taskr-net >/dev/null 2>&1 || { echo "create the network taskr-net first (Part A)"; exit 1; }
docker rm -f taskr-planted >/dev/null 2>&1 || true

docker run -d --name taskr-planted \
  --restart always \
  -p 127.0.0.1:8090:8080 \
  -e DATABASE_URL=postgresql://taskr:taskr-lab@db:5432/taskr \
  taskr:2.0 >/dev/null

echo "Started the container taskr-planted. Something is wrong with it."
echo "Start with:  docker ps -a --filter name=taskr-planted"
