#!/usr/bin/env bash
# Runs shell commands on the EC2 instance through SSM Run Command and waits for the result.
# Used by setup.sh (from a laptop) and by the deploy workflow (from GitHub Actions). No SSH needed.
#
#   ssm-run.sh <instance-id> <region> <timeout-seconds> <comment> <command> [<command> ...]
#
# Prints the command's output; exits non-zero if it fails or times out.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: don't rewrite /opt/... arguments into C:/...

[ $# -ge 5 ] || { echo "usage: $0 <instance-id> <region> <timeout-s> <comment> <command>..." >&2; exit 2; }
INSTANCE_ID=$1 REGION=$2 TIMEOUT=$3 COMMENT=$4
shift 4

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
items=""
for c in "$@"; do
  items="${items:+$items,}\"$(json_escape "$c")\""
done

CMD_ID=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --comment "${COMMENT:0:100}" \
  --parameters "{\"commands\":[$items],\"executionTimeout\":[\"$TIMEOUT\"]}" \
  --query Command.CommandId --output text)
echo "SSM command $CMD_ID sent to $INSTANCE_ID: $COMMENT"

deadline=$(( $(date +%s) + TIMEOUT + 30 ))
status=Pending
while :; do
  sleep 5
  status=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)
  case "$status" in
    Pending|InProgress|Delayed) ;;
    *) break ;;
  esac
  if [ "$(date +%s)" -gt "$deadline" ]; then
    echo "ERROR: timed out waiting for SSM command $CMD_ID" >&2
    exit 1
  fi
done

aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text
echo "SSM status: $status"
[ "$status" = "Success" ]
