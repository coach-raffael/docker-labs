#!/usr/bin/env bash
# Day 5, Module 18: acceptance checks for "Run taskr on a three-node swarm".
# Expects: a swarm with three ready nodes (this engine as manager, worker1 and worker2 from
# swarm/workers.sh), stack "taskr" deployed from your repaired copy of broken/day5/stack.yaml:
# taskr_taskr with three replicas from 127.0.0.1:5000/taskr, taskr_db pinned to the node with the
# label taskr.db=true, passwords as swarm secrets.
# Run on the manager from the repository root:  ./checks/day5.sh
set -u
. "$(dirname "$0")/lib.sh"
STACK=taskr

echo "Part A: deploy"
ready="$(docker node ls --format '{{.Status}}' 2>/dev/null | grep -c Ready)"
if [ "${ready:-0}" -eq 3 ]; then ok "three nodes are Ready"; else fail "$ready nodes are Ready, expected 3 (swarm/workers.sh up, docker swarm join)"; fi
check "stack $STACK is deployed" docker stack services "$STACK"
replicas="$(docker service ls --filter name=${STACK}_taskr --format '{{.Replicas}}' 2>/dev/null)"
case "$replicas" in
  3/3*) ok "service ${STACK}_taskr runs 3/3 replicas ($replicas)" ;;
  *) fail "service ${STACK}_taskr replicas: ${replicas:-none}, expected 3/3" ;;
esac
dbreplicas="$(docker service ls --filter name=${STACK}_db --format '{{.Replicas}}' 2>/dev/null)"
if [ "$dbreplicas" = "1/1" ]; then ok "service ${STACK}_db runs 1/1 replica"; else fail "service ${STACK}_db replicas: ${dbreplicas:-none}, expected 1/1"; fi

image="$(docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' ${STACK}_taskr 2>/dev/null || true)"
if contains "127.0.0.1:5000/taskr" "$image"; then ok "taskr image comes from your registry ($image)"; else fail "taskr image is '${image:-none}', expected 127.0.0.1:5000/taskr:<tag>"; fi
constraints="$(docker service inspect --format '{{json .Spec.TaskTemplate.Placement.Constraints}}' ${STACK}_db 2>/dev/null || true)"
if contains "node.labels.taskr.db" "$constraints"; then ok "db is pinned with a node label constraint"; else fail "db placement constraints: ${constraints:-none}, expected node.labels.taskr.db == true"; fi
label="$(docker node inspect self --format '{{index .Spec.Labels "taskr.db"}}' 2>/dev/null || true)"
if [ "$label" = "true" ]; then ok "the manager carries the label taskr.db=true"; else fail "the manager has no label taskr.db=true"; fi

for svc in taskr db; do
  secrets="$(docker service inspect --format '{{json .Spec.TaskTemplate.ContainerSpec.Secrets}}' ${STACK}_$svc 2>/dev/null || true)"
  if [ -n "$secrets" ] && [ "$secrets" != "null" ]; then ok "${STACK}_$svc uses swarm secrets"; else fail "${STACK}_$svc uses no swarm secret"; fi
  env="$(docker service inspect --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' ${STACK}_$svc 2>/dev/null || true)"
  if [ -z "$env" ] || [ "$env" = "null" ]; then
    fail "${STACK}_$svc has no environment at all (expected POSTGRES_PASSWORD_FILE or DATABASE_URL_FILE)"
  elif contains "taskr-lab" "$env"; then
    fail "${STACK}_$svc still carries the password in its environment"
  else
    ok "${STACK}_$svc has no password in its environment"
  fi
done

health="$(http_body http://127.0.0.1:8080/health 2>/dev/null || true)"
if json_has storage postgresql "$health" && json_has status ok "$health"; then ok "GET /health through the routing mesh reports storage postgresql"; else fail "GET /health: ${health:-no answer}"; fi
hosts="$(for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do http_body http://127.0.0.1:8080/stats 2>/dev/null | grep -o '"hostname":"[^"]*"'; done | sort -u | wc -l | tr -d ' ')"
if [ "${hosts:-0}" -ge 2 ]; then ok "requests reach at least two different replicas ($hosts hostnames seen)"; else fail "all requests reached the same replica"; fi

echo "Part B: operate (information only, run this again after the drain and the update)"
version="$(printf '%s' "$health" | grep -o '"version":"[^"]*"')"
echo "  current version: ${version:-unknown} (2.3.0 after the rolling update)"
drained="$(docker node ls --format '{{.Hostname}} {{.Availability}}' 2>/dev/null | grep -c Drain)"
echo "  drained nodes: $drained"
update="$(docker service inspect --format 'order={{.Spec.UpdateConfig.Order}} failure_action={{.Spec.UpdateConfig.FailureAction}}' ${STACK}_taskr 2>/dev/null || true)"
echo "  update config of ${STACK}_taskr: ${update:-none} (expected order=start-first failure_action=rollback)"

summary
