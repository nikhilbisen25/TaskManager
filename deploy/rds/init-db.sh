#!/usr/bin/env bash
# Creates authdb/taskdb and their users on RDS. Run as root on the EC2 instance (setup.sh runs it via SSM).
# The RDS master password is managed by RDS in Secrets Manager: this script reads it with the
# instance role, so nobody ever types or sees it. App passwords come from /opt/taskmanager/.env.
set -euo pipefail
cd /opt/taskmanager
# shellcheck disable=SC1091
source .env

SECRET_JSON=$(aws secretsmanager get-secret-value --region "$AWS_REGION" \
  --secret-id "$RDS_SECRET_ARN" --query SecretString --output text)
MASTER_USER=$(printf '%s' "$SECRET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])')
MASTER_PW=$(printf '%s' "$SECRET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')

docker run --rm -i -e PGPASSWORD="$MASTER_PW" postgres:16-alpine \
  psql "host=$RDS_HOST port=5432 dbname=postgres user=$MASTER_USER sslmode=require" \
  -v ON_ERROR_STOP=1 -v auth_pw="$AUTH_DB_PASSWORD" -v task_pw="$TASK_DB_PASSWORD" \
  < rds/init.sql
echo "RDS INIT OK"
