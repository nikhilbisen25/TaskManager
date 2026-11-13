#!/usr/bin/env bash
# Look at the live AWS system from this laptop (Git Bash), via SSM Run Command: no SSH, no open ports.
# Needs the AWS CLI configured (aws configure) with access to the taskmanager resources.
#
#   ./scripts/aws.sh logs [auth|task] [lines]     recent backend logs (default: both, 100 lines)
#   ./scripts/aws.sh db summary                   users + task counts + latest tasks from RDS
#   ./scripts/aws.sh db task "select ..."         one SQL query on taskdb (or: db auth "...")
#   ./scripts/aws.sh status                       deployed tags, container health, disk/memory
#
# For LIVE following (logs -f) or an interactive psql, use Session Manager in the AWS console
# (EC2 → instance → Connect → Session Manager) and run the same scripts there; see docs/OBSERVABILITY.md.
set -euo pipefail
export MSYS_NO_PATHCONV=1
export AWS_PAGER=""
REGION="${AWS_REGION:-ap-south-1}"
cd "$(dirname "$0")/.."

ID=$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Name,Values=taskmanager-ec2" \
  "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ -n "$ID" ] && [ "$ID" != "None" ] || { echo "taskmanager-ec2 is not running" >&2; exit 1; }

run() { ./deploy/aws/ssm-run.sh "$ID" "$REGION" 120 "$1" "$2"; }
q() { printf '%q' "$1"; }   # shell-quote an argument for the remote bash

case "${1:-}" in
  logs) shift; run "logs" "bash /opt/taskmanager/ec2/logs.sh $*" ;;
  db)
    shift
    [ $# -ge 1 ] || { sed -n '5,8p' "$0"; exit 2; }
    if [ $# -ge 2 ]; then run "db query" "bash /opt/taskmanager/ec2/db.sh $1 $(q "$2")"
    else run "db $1" "bash /opt/taskmanager/ec2/db.sh $1 </dev/null"; fi ;;
  status)
    run "status" "cd /opt/taskmanager && cat tags.env && docker ps --format 'table {{.Names}}\t{{.Status}}' && free -m && df -h / | tail -1" ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
