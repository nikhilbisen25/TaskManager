#!/usr/bin/env bash
# End-to-end API check through the single public origin (nginx locally, CloudFront in AWS).
#   ./scripts/smoke-test.sh                       # local docker-compose (http://localhost:8080)
#   ./scripts/smoke-test.sh https://dxxxx.cloudfront.net
# Registers a throwaway user, logs in, then exercises task create/list/update/status/delete.
set -euo pipefail

BASE="${1:-http://localhost:8080}"
EMAIL="smoke-$(date +%s)-$RANDOM@example.com"
PASS="smoke-pass-123"
JSON='Content-Type: application/json'

step() { printf '\n== %s\n' "$1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
field() { sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p"; }   # tiny JSON field extractor (no jq needed)

step "health"
curl -fsS "$BASE/api/auth/health" || fail "auth-service health"
echo

step "register $EMAIL"
curl -fsS -X POST "$BASE/api/auth/register" -H "$JSON" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"full_name\":\"Smoke Test\"}" || fail "register"
echo

step "login"
TOKEN=$(curl -fsS -X POST "$BASE/api/auth/login" -H "$JSON" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | field access_token)
[ -n "$TOKEN" ] || fail "no token"
AUTH="Authorization: Bearer $TOKEN"
echo "got token (${#TOKEN} chars)"

step "unauthenticated /api/tasks is rejected"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/tasks")
[ "$CODE" = "401" ] || fail "expected 401, got $CODE"
echo "401 ok"

step "create task"
ID=$(curl -fsS -X POST "$BASE/api/tasks" -H "$JSON" -H "$AUTH" \
  -d '{"title":"Smoke task","description":"created by smoke-test.sh"}' | field id)
[ -n "$ID" ] || fail "no task id"
echo "id=$ID"

step "list tasks"
curl -fsS "$BASE/api/tasks?status=TODO" -H "$AUTH" | grep -q "Smoke task" || fail "task not listed"
echo "listed ok"

step "update task"
curl -fsS -X PUT "$BASE/api/tasks/$ID" -H "$JSON" -H "$AUTH" \
  -d '{"title":"Smoke task (edited)","description":null,"status":"IN_PROGRESS"}' | grep -q "edited" || fail "update"
echo "updated ok"

step "change status"
curl -fsS -X PATCH "$BASE/api/tasks/$ID/status" -H "$JSON" -H "$AUTH" -d '{"status":"DONE"}' \
  | grep -q '"DONE"' || fail "status"
echo "status ok"

step "delete task"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$BASE/api/tasks/$ID" -H "$AUTH")
[ "$CODE" = "204" ] || fail "expected 204, got $CODE"
echo "deleted ok"

printf '\nALL CHECKS PASSED against %s\n' "$BASE"
