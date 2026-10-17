#!/usr/bin/env bash
# Day 5, Modules 16 to 18: the two worker nodes of your swarm lab.
# Your own Docker Engine becomes the manager (docker swarm init). The workers worker1 and worker2
# are Docker-in-Docker containers (image docker:29-dind) on the network swarm-lab. This script only
# starts and removes them; you join them to the swarm yourself in Module 16.
#
#   swarm/workers.sh up       create the network and start both workers, print the manager address
#   swarm/workers.sh status   show the workers and whether their engines answer
#   swarm/workers.sh down     remove both workers, their volumes and the network
#
# docker:dind needs --privileged (see https://hub.docker.com/_/docker). Run this on a lab machine,
# not on a computer you care about.
set -euo pipefail

IMAGE="docker:29-dind"
NETWORK="swarm-lab"
WORKERS="worker1 worker2"

manager_address() {
  docker network inspect "$NETWORK" --format '{{(index .IPAM.Config 0).Gateway}}'
}

wait_for_engine() {
  local worker="$1" tries=0
  until docker exec "$worker" docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
      echo "  $worker: engine did not come up, check: docker logs $worker" >&2
      return 1
    fi
    sleep 2
  done
}

up() {
  if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    docker network create "$NETWORK" >/dev/null
    echo "created network $NETWORK"
  fi
  for worker in $WORKERS; do
    if docker inspect "$worker" >/dev/null 2>&1; then
      echo "$worker already exists, starting it if needed"
      docker start "$worker" >/dev/null
    else
      docker run -d --name "$worker" --hostname "$worker" \
        --privileged \
        --network "$NETWORK" \
        --restart unless-stopped \
        -v "swarm-$worker:/var/lib/docker" \
        "$IMAGE" >/dev/null
      echo "started $worker"
    fi
  done
  for worker in $WORKERS; do
    printf '  waiting for the engine in %s ...' "$worker"
    wait_for_engine "$worker"
    echo " ready"
  done
  echo
  echo "Address of this engine on the network $NETWORK, your manager address: $(manager_address)"
  echo "Module 16 shows how to create the swarm and how to join the workers."
  echo "The engine inside a worker answers to: docker exec worker1 docker <command>"
}

status() {
  docker ps -a --filter "name=^worker[12]$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  for worker in $WORKERS; do
    if info="$(docker exec "$worker" docker info --format 'engine {{.ServerVersion}}, swarm state {{.Swarm.LocalNodeState}}' 2>/dev/null)"; then
      echo "$worker: $info"
    else
      echo "$worker: engine not reachable"
    fi
  done
}

down() {
  for worker in $WORKERS; do
    docker rm -f "$worker" >/dev/null 2>&1 && echo "removed $worker" || true
    docker volume rm "swarm-$worker" >/dev/null 2>&1 && echo "removed volume swarm-$worker" || true
  done
  docker network rm "$NETWORK" >/dev/null 2>&1 && echo "removed network $NETWORK" || true
}

case "${1:-}" in
  up) up ;;
  status) status ;;
  down) down ;;
  *) echo "usage: $0 up|status|down" >&2; exit 2 ;;
esac
