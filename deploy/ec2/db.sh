#!/usr/bin/env bash
# Look inside the RDS databases from the EC2 instance (RDS is private; this instance is the way in).
# Run as root (Session Manager: `sudo bash ...`). Uses each service's own DB user from .env.
#
#   db.sh summary                      users, their task counts, latest tasks (joins both DBs by user id)
#   db.sh auth                         interactive psql on authdb  (\dt, \d users, \q to quit)
#   db.sh task                         interactive psql on taskdb
#   db.sh auth "select ..."            run one query
#   db.sh task "select ..."
set -euo pipefail
cd /opt/taskmanager
# shellcheck disable=SC1091
source .env

psql_db() {  # psql_db <db> <user> <password> [psql args...]
  local db=$1 user=$2 pw=$3; shift 3
  local tty=(-i)
  if [ $# -eq 0 ] && [ -t 0 ]; then tty=(-it); fi
  docker run --rm "${tty[@]}" -e PGPASSWORD="$pw" postgres:16-alpine \
    psql "host=$RDS_HOST port=5432 dbname=$db user=$user sslmode=require" "$@"
}
auth_db() { psql_db authdb auth "$AUTH_DB_PASSWORD" "$@"; }
task_db() { psql_db taskdb task "$TASK_DB_PASSWORD" "$@"; }

case "${1:-}" in
  auth) shift; if [ $# -gt 0 ]; then auth_db -c "$1"; else auth_db; fi ;;
  task) shift; if [ $# -gt 0 ]; then task_db -c "$1"; else task_db; fi ;;
  summary)
    # The databases are separate (database per service), so there is no SQL join across them:
    # read both and match tasks.owner_id to users.id here.
    users=$(auth_db -At -F'|' -c "select id, email from users order by created_at" </dev/null)
    counts=$(task_db -At -F'|' -c "select owner_id,
        count(*) filter (where status = 'TODO'),
        count(*) filter (where status = 'IN_PROGRESS'),
        count(*) filter (where status = 'DONE')
      from tasks group by owner_id" </dev/null)
    echo "== Users and their tasks (authdb.users joined to taskdb.tasks by user id)"
    printf '%-38s %-40s %5s %5s %5s\n' "user id" "email" "todo" "doing" "done"
    awk -F'|' -v counts="$counts" '
      BEGIN { n = split(counts, rows, "\n"); for (i = 1; i <= n; i++) { split(rows[i], c, "|"); t[c[1]] = c[2]; p[c[1]] = c[3]; d[c[1]] = c[4] } }
      NF { printf "%-38s %-40s %5d %5d %5d\n", $1, $2, t[$1], p[$1], d[$1] }' <<< "$users"
    echo
    echo "== Latest 10 tasks (taskdb.tasks)"
    task_db -c "select id, owner_id, left(title, 40) as title, status, updated_at
                from tasks order by updated_at desc limit 10" </dev/null
    echo "== Applied migrations"
    auth_db -At -c "select 'authdb alembic: ' || version_num from alembic_version" </dev/null
    task_db -At -c "select 'taskdb flyway:  V' || version || ' ' || description from flyway_schema_history where success order by installed_rank" </dev/null
    ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
