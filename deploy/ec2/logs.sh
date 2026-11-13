#!/usr/bin/env bash
# Backend container logs on the EC2 instance. Run as root (Session Manager: `sudo bash ...`).
#
#   logs.sh              last 100 lines of both services
#   logs.sh -f           follow live (Ctrl+C to stop): use this while clicking around the app
#   logs.sh task 200     one service (auth | task), last 200 lines
set -euo pipefail
cd /opt/taskmanager

follow=() services=() lines=100
for arg in "$@"; do
  case "$arg" in
    -f) follow=(-f) ;;
    auth|task) services+=("$arg-service") ;;
    ''|*[!0-9]*) echo "usage: $0 [-f] [auth|task] [lines]" >&2; exit 2 ;;
    *) lines=$arg ;;
  esac
done

exec docker compose -f docker-compose.prod.yml --env-file .env --env-file tags.env \
  logs --timestamps --tail "$lines" "${follow[@]}" "${services[@]}"
