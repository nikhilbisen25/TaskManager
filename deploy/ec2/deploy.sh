#!/usr/bin/env bash
# Deploys backend images on the EC2 instance. Run as root (GitHub Actions runs it via SSM).
#
#   deploy.sh auth=<sha> task=<sha>   deploy new image tags (either or both)
#   deploy.sh                         re-apply current tags (e.g. after a compose file change)
#   deploy.sh rollback                go back to the tags used before the last deploy
#
# Fails (non-zero) if the containers don't become healthy, so the pipeline goes red.
set -euo pipefail
cd /opt/taskmanager
[ -f .env ] || { echo "ERROR: /opt/taskmanager/.env missing (run make-env.sh first)" >&2; exit 1; }
# shellcheck disable=SC1091
source .env
touch tags.env

set_tag() {  # set_tag KEY VALUE  -> replaces KEY=... in tags.env
  grep -v "^$1=" tags.env > tags.env.tmp || true
  echo "$1=$2" >> tags.env.tmp
  mv tags.env.tmp tags.env
}

if [ "${1:-}" = "rollback" ]; then
  [ -f tags.env.prev ] || { echo "ERROR: no previous deploy to roll back to" >&2; exit 1; }
  cp tags.env tags.env.failed
  cp tags.env.prev tags.env
  echo "Rolling back to:"; cat tags.env
else
  cp tags.env tags.env.prev
  for arg in "$@"; do
    case "$arg" in
      auth=*) set_tag AUTH_TAG "${arg#auth=}" ;;
      task=*) set_tag TASK_TAG "${arg#task=}" ;;
      *) echo "ERROR: unknown argument '$arg'" >&2; exit 2 ;;
    esac
  done
fi
echo "Deploying tags:"; cat tags.env

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null

compose=(docker compose -f docker-compose.prod.yml --env-file .env --env-file tags.env)
"${compose[@]}" pull --quiet
# --wait blocks until every container's HEALTHCHECK passes (Spring Boot cold start is the slow part).
if ! "${compose[@]}" up -d --remove-orphans --wait --wait-timeout 240; then
  echo "ERROR: containers did not become healthy. Recent logs:" >&2
  "${compose[@]}" ps >&2 || true
  "${compose[@]}" logs --tail 60 >&2 || true
  exit 1
fi
"${compose[@]}" ps
docker image prune -f >/dev/null
echo "DEPLOY OK"
