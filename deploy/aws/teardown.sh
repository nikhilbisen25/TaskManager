#!/usr/bin/env bash
# Deletes EVERYTHING setup.sh created (stops all costs). Irreversible: databases and images are gone.
#
#   ./deploy/aws/teardown.sh --yes-delete-everything
#
# Takes ~15-20 minutes, mostly waiting for CloudFront to disable and RDS to delete.
set -uo pipefail          # no -e: keep going if one resource is already gone
export MSYS_NO_PATHCONV=1
export AWS_PAGER=""

[ "${1:-}" = "--yes-delete-everything" ] || { sed -n '2,7p' "$0"; exit 2; }

REGION="${AWS_REGION:-ap-south-1}"
P=taskmanager
export AWS_DEFAULT_REGION="$REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || exit 1
log() { printf '\n\033[1;31m== %s\033[0m\n' "$*"; }
has() { [ -n "${1:-}" ] && [ "$1" != "None" ] && [ "$1" != "null" ]; }

log "CloudFront distribution (disable, wait, delete)"
DIST=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$P'].Id | [0]" --output text)
if has "$DIST"; then
  ETAG=$(aws cloudfront get-distribution-config --id "$DIST" --query ETag --output text)
  # Our config has exactly one "Enabled": true (the distribution itself), so this flips only that.
  CONFIG=$(aws cloudfront get-distribution-config --id "$DIST" --query DistributionConfig --output json \
    | sed 's/"Enabled": true/"Enabled": false/')
  aws cloudfront update-distribution --id "$DIST" --if-match "$ETAG" --distribution-config "$CONFIG" >/dev/null
  echo "   disabling $DIST (waiting for deployment, ~5-10 min)"
  aws cloudfront wait distribution-deployed --id "$DIST"
  ETAG=$(aws cloudfront get-distribution-config --id "$DIST" --query ETag --output text)
  aws cloudfront delete-distribution --id "$DIST" --if-match "$ETAG" && echo "   deleted $DIST"
fi
if aws cloudfront describe-function --name "$P-spa-rewrite" >/dev/null 2>&1; then
  ETAG=$(aws cloudfront describe-function --name "$P-spa-rewrite" --query ETag --output text)
  aws cloudfront delete-function --name "$P-spa-rewrite" --if-match "$ETAG" && echo "   deleted function"
fi
OAC=$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='$P-oac'].Id | [0]" --output text)
if has "$OAC"; then
  ETAG=$(aws cloudfront get-origin-access-control --id "$OAC" --query ETag --output text)
  aws cloudfront delete-origin-access-control --id "$OAC" --if-match "$ETAG" && echo "   deleted OAC"
fi

log "EC2 instance + Elastic IP, RDS (in parallel)"
ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$P-ec2" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
has "$ID" && aws ec2 terminate-instances --instance-ids "$ID" >/dev/null && echo "   terminating $ID"
aws rds delete-db-instance --db-instance-identifier "$P-db" --skip-final-snapshot \
  --delete-automated-backups >/dev/null 2>&1 && echo "   deleting RDS $P-db (also deletes its managed secret)"
has "$ID" && aws ec2 wait instance-terminated --instance-ids "$ID"
ALLOC=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$P-eip" --query 'Addresses[0].AllocationId' --output text)
has "$ALLOC" && aws ec2 release-address --allocation-id "$ALLOC" && echo "   released Elastic IP"

log "S3 buckets and ECR repositories"
for b in "$P-web-$ACCOUNT_ID" "$P-deploy-$ACCOUNT_ID"; do
  aws s3 rb "s3://$b" --force >/dev/null 2>&1 && echo "   deleted $b"
done
for r in auth-service task-service; do
  aws ecr delete-repository --repository-name "$P/$r" --force >/dev/null 2>&1 && echo "   deleted $P/$r"
done

log "IAM roles, instance profile, OIDC provider"
aws iam remove-role-from-instance-profile --instance-profile-name "$P-ec2-profile" --role-name "$P-ec2-role" 2>/dev/null
aws iam delete-instance-profile --instance-profile-name "$P-ec2-profile" 2>/dev/null && echo "   deleted instance profile"
for arn in arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly; do
  aws iam detach-role-policy --role-name "$P-ec2-role" --policy-arn "$arn" 2>/dev/null
done
aws iam delete-role-policy --role-name "$P-ec2-role" --policy-name "$P-ec2-access" 2>/dev/null
aws iam delete-role --role-name "$P-ec2-role" 2>/dev/null && echo "   deleted $P-ec2-role"
aws iam delete-role-policy --role-name "$P-github-deploy" --policy-name "$P-deploy" 2>/dev/null
aws iam delete-role --role-name "$P-github-deploy" 2>/dev/null && echo "   deleted $P-github-deploy"
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com" 2>/dev/null \
  && echo "   deleted GitHub OIDC provider"

log "Security groups (after RDS is gone)"
echo "   waiting for RDS deletion (~5-10 min)"
aws rds wait db-instance-deleted --db-instance-identifier "$P-db" 2>/dev/null
VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
for sg in "$P-db-sg" "$P-app-sg"; do
  SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$sg" "Name=vpc-id,Values=$VPC" \
    --query 'SecurityGroups[0].GroupId' --output text)
  has "$SG" && aws ec2 delete-security-group --group-id "$SG" && echo "   deleted $sg"
done

printf '\nTeardown finished. Check Billing → Bills over the next day to confirm charges stopped.\n'
