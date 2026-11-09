#!/usr/bin/env bash
# Creates the AWS infrastructure for the Task Manager, one step at a time.
# Every step looks resources up by name first, so re-running a step is safe.
#
#   GITHUB_REPO=owner/name ./deploy/aws/setup.sh <step>
#
# Steps, in order (or "all"):
#   network     security groups: app (8001-8002 from CloudFront only), db (5432 from app only)
#   rds         RDS PostgreSQL 16, db.t4g.micro, private, master password managed in Secrets Manager
#   ecr         ECR repositories for both service images (keeps the last 15 images)
#   buckets     private S3 buckets: web (frontend) and deploy (compose file + scripts for EC2)
#   iam-ec2     EC2 instance role: SSM, ECR pull, read deploy bucket, read RDS master secret
#   ec2         t3.micro Amazon Linux 2023 + user-data + Elastic IP
#   cloudfront  OAC, SPA rewrite function, distribution (S3 default, /api/auth/* and /api/tasks* to EC2)
#   github      GitHub OIDC provider + deploy role (needs GITHUB_REPO)
#   bootstrap   waits for RDS + EC2, then on EC2: sync files, make-env.sh, init-db.sh
#   outputs     prints the values to set as GitHub Actions variables
#
# Requires AWS CLI v2 configured with an admin profile (aws configure / aws configure sso).
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: keep /aws/... and /index.html arguments as-is
export AWS_PAGER=""

cd "$(dirname "$0")/../.."   # repo root, so relative file:// paths work
REGION="${AWS_REGION:-ap-south-1}"
P=taskmanager
export AWS_DEFAULT_REGION="$REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
WEB_BUCKET="$P-web-$ACCOUNT_ID"
DEPLOY_BUCKET="$P-deploy-$ACCOUNT_ID"
DB_ID="$P-db"

log() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok() { printf '   %s\n' "$*"; }
has() { [ -n "${1:-}" ] && [ "$1" != "None" ] && [ "$1" != "null" ]; }

# ---------- lookups (return "None" when missing) ----------
vpc_id() { aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text; }
sg_id() {
  aws ec2 describe-security-groups --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$(vpc_id)" \
    --query 'SecurityGroups[0].GroupId' --output text
}
instance_id() {
  aws ec2 describe-instances --filters "Name=tag:Name,Values=$P-ec2" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}
instance_dns() { aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PublicDnsName' --output text; }
distribution_id() {
  aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$P'].Id | [0]" --output text
}
oac_id() {
  aws cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='$P-oac'].Id | [0]" --output text
}
rds_field() { aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query "DBInstances[0].$1" --output text 2>/dev/null || echo None; }

# ---------- steps ----------
step_network() {
  log "network: security groups"
  local vpc app db pl
  vpc=$(vpc_id); has "$vpc" || { echo "No default VPC in $REGION" >&2; exit 1; }
  ok "default VPC $vpc"

  app=$(sg_id "$P-app-sg")
  if ! has "$app"; then
    app=$(aws ec2 create-security-group --group-name "$P-app-sg" --vpc-id "$vpc" \
      --description "Task Manager backends: only CloudFront may connect" --query GroupId --output text)
    pl=$(aws ec2 describe-managed-prefix-lists \
      --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
      --query 'PrefixLists[0].PrefixListId' --output text)
    # One rule for the port range: a prefix-list rule counts ~55 entries against the 60-rule SG quota.
    aws ec2 authorize-security-group-ingress --group-id "$app" --ip-permissions \
      "IpProtocol=tcp,FromPort=8001,ToPort=8002,PrefixListIds=[{PrefixListId=$pl,Description=CloudFront}]" >/dev/null
    ok "created $P-app-sg $app (8001-8002 from CloudFront prefix list $pl)"
  else ok "exists $P-app-sg $app"; fi

  db=$(sg_id "$P-db-sg")
  if ! has "$db"; then
    db=$(aws ec2 create-security-group --group-name "$P-db-sg" --vpc-id "$vpc" \
      --description "Task Manager RDS: only the app instance may connect" --query GroupId --output text)
    aws ec2 authorize-security-group-ingress --group-id "$db" --protocol tcp --port 5432 \
      --source-group "$app" >/dev/null
    ok "created $P-db-sg $db (5432 from $P-app-sg)"
  else ok "exists $P-db-sg $db"; fi
}

step_rds() {
  log "rds: PostgreSQL 16 ($DB_ID)"
  if has "$(rds_field DBInstanceStatus)"; then ok "exists, status $(rds_field DBInstanceStatus)"; return; fi
  local version db
  version=$(aws rds describe-db-engine-versions --engine postgres \
    --query "DBEngineVersions[?starts_with(EngineVersion, '16.')].EngineVersion | [-1]" --output text)
  db=$(sg_id "$P-db-sg"); has "$db" || { echo "Run the network step first" >&2; exit 1; }
  aws rds create-db-instance --db-instance-identifier "$DB_ID" \
    --engine postgres --engine-version "$version" --db-instance-class db.t4g.micro \
    --allocated-storage 20 --storage-type gp3 \
    --master-username tmadmin --manage-master-user-password \
    --vpc-security-group-ids "$db" --no-publicly-accessible --no-multi-az \
    --backup-retention-period 1 --no-deletion-protection \
    --tags "Key=Project,Value=$P" >/dev/null
  ok "creating Postgres $version (about 10 minutes; the bootstrap step waits for it)"
}

step_ecr() {
  log "ecr: image repositories"
  local svc
  for svc in auth-service task-service; do
    if aws ecr describe-repositories --repository-names "$P/$svc" >/dev/null 2>&1; then
      ok "exists $P/$svc"
    else
      aws ecr create-repository --repository-name "$P/$svc" \
        --image-scanning-configuration scanOnPush=true >/dev/null
      aws ecr put-lifecycle-policy --repository-name "$P/$svc" --lifecycle-policy-text \
        '{"rules":[{"rulePriority":1,"description":"keep last 15","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":15},"action":{"type":"expire"}}]}' >/dev/null
      ok "created $P/$svc"
    fi
  done
}

step_buckets() {
  log "buckets: $WEB_BUCKET, $DEPLOY_BUCKET"
  local b
  for b in "$WEB_BUCKET" "$DEPLOY_BUCKET"; do
    if aws s3api head-bucket --bucket "$b" 2>/dev/null; then ok "exists $b"; continue; fi
    aws s3api create-bucket --bucket "$b" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    aws s3api put-public-access-block --bucket "$b" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    ok "created $b (private)"
  done
}

step_iam_ec2() {
  log "iam-ec2: instance role $P-ec2-role"
  if ! aws iam get-role --role-name "$P-ec2-role" >/dev/null 2>&1; then
    aws iam create-role --role-name "$P-ec2-role" --assume-role-policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    ok "created role"
  else ok "role exists"; fi
  aws iam attach-role-policy --role-name "$P-ec2-role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam attach-role-policy --role-name "$P-ec2-role" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
  aws iam put-role-policy --role-name "$P-ec2-role" --policy-name "$P-ec2-access" --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"arn:aws:s3:::$DEPLOY_BUCKET\"},
      {\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$DEPLOY_BUCKET/*\"},
      {\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",
       \"Resource\":\"arn:aws:secretsmanager:$REGION:$ACCOUNT_ID:secret:rds!*\"}
    ]}"
  ok "policies attached (SSM core, ECR read-only, deploy bucket read, RDS master secret read)"
  if ! aws iam get-instance-profile --instance-profile-name "$P-ec2-profile" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$P-ec2-profile" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$P-ec2-profile" --role-name "$P-ec2-role"
    ok "created instance profile $P-ec2-profile"
  else ok "instance profile exists"; fi
}

step_ec2() {
  log "ec2: $P-ec2 (t3.micro, Amazon Linux 2023)"
  local id app alloc i
  id=$(instance_id)
  if ! has "$id"; then
    app=$(sg_id "$P-app-sg"); has "$app" || { echo "Run the network step first" >&2; exit 1; }
    for i in 1 2 3 4 5 6; do   # a new instance profile takes a few seconds to become usable
      if id=$(aws ec2 run-instances --instance-type t3.micro \
          --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
          --iam-instance-profile "Name=$P-ec2-profile" --security-group-ids "$app" \
          --user-data file://deploy/ec2/user-data.sh \
          --metadata-options HttpTokens=required,HttpEndpoint=enabled \
          --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=16,VolumeType=gp3}' \
          --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$P-ec2},{Key=Project,Value=$P}]" \
          --query 'Instances[0].InstanceId' --output text 2>/dev/null); then break; fi
      ok "instance profile not ready yet, retrying in 10s ($i/6)"; sleep 10; id=""
    done
    has "$id" || { echo "run-instances failed" >&2; exit 1; }
    ok "launched $id, waiting for running state"
    aws ec2 wait instance-running --instance-ids "$id"
  else ok "exists $id"; fi

  alloc=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$P-eip" \
    --query 'Addresses[0].AllocationId' --output text)
  if ! has "$alloc"; then
    alloc=$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$P-eip},{Key=Project,Value=$P}]" \
      --query AllocationId --output text)
    ok "allocated Elastic IP $alloc"
  fi
  aws ec2 associate-address --instance-id "$id" --allocation-id "$alloc" >/dev/null
  sleep 3
  ok "public DNS (CloudFront origin): $(instance_dns "$id")"
}

step_cloudfront() {
  log "cloudfront: distribution"
  local oac fn_etag fn_arn id dns dist_id dist_arn
  id=$(instance_id); has "$id" || { echo "Run the ec2 step first" >&2; exit 1; }
  dns=$(instance_dns "$id")

  oac=$(oac_id)
  if ! has "$oac"; then
    oac=$(aws cloudfront create-origin-access-control --origin-access-control-config \
      "Name=$P-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
      --query OriginAccessControl.Id --output text)
    ok "created OAC $oac"
  else ok "OAC exists $oac"; fi

  if ! aws cloudfront describe-function --name "$P-spa-rewrite" >/dev/null 2>&1; then
    aws cloudfront create-function --name "$P-spa-rewrite" \
      --function-config "Comment=SPA routes to index.html,Runtime=cloudfront-js-2.0" \
      --function-code fileb://deploy/cloudfront/spa-rewrite.js >/dev/null
    ok "created function $P-spa-rewrite"
  else
    fn_etag=$(aws cloudfront describe-function --name "$P-spa-rewrite" --query ETag --output text)
    aws cloudfront update-function --name "$P-spa-rewrite" --if-match "$fn_etag" \
      --function-config "Comment=SPA routes to index.html,Runtime=cloudfront-js-2.0" \
      --function-code fileb://deploy/cloudfront/spa-rewrite.js >/dev/null
    ok "updated function code"
  fi
  fn_etag=$(aws cloudfront describe-function --name "$P-spa-rewrite" --query ETag --output text)
  aws cloudfront publish-function --name "$P-spa-rewrite" --if-match "$fn_etag" >/dev/null
  fn_arn=$(aws cloudfront describe-function --name "$P-spa-rewrite" --stage LIVE \
    --query FunctionSummary.FunctionMetadata.FunctionARN --output text)

  dist_id=$(distribution_id)
  if has "$dist_id"; then
    ok "distribution exists $dist_id (to change its config, edit it in the console or delete and re-run)"
  else
    # Managed policy IDs (same in every account):
    #   CachingOptimized 658327ea-f89d-4fab-a63d-7e88639e58f6 · CachingDisabled 4135ea2d-6df8-44a3-9df3-4b5a84be39ad
    #   AllViewerExceptHostHeader b689b0a8-53d0-40ab-baf2-68738e2966ac (forwards Authorization, query strings)
    api_origin() {  # api_origin <id> <port>
      printf '{"Id":"%s","DomainName":"%s","CustomOriginConfig":{"HTTPPort":%s,"HTTPSPort":443,"OriginProtocolPolicy":"http-only","OriginSslProtocols":{"Quantity":1,"Items":["TLSv1.2"]},"OriginReadTimeout":30,"OriginKeepaliveTimeout":5}}' "$1" "$dns" "$2"
    }
    api_behavior() {  # api_behavior <path-pattern> <origin-id>
      printf '{"PathPattern":"%s","TargetOriginId":"%s","ViewerProtocolPolicy":"redirect-to-https","AllowedMethods":{"Quantity":7,"Items":["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],"CachedMethods":{"Quantity":2,"Items":["GET","HEAD"]}},"Compress":true,"CachePolicyId":"4135ea2d-6df8-44a3-9df3-4b5a84be39ad","OriginRequestPolicyId":"b689b0a8-53d0-40ab-baf2-68738e2966ac"}' "$1" "$2"
    }
    local config
    config=$(cat <<EOF
{
  "CallerReference": "$P-$(date +%s)",
  "Comment": "$P",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "PriceClass": "PriceClass_200",
  "HttpVersion": "http2and3",
  "IsIPV6Enabled": true,
  "ViewerCertificate": {"CloudFrontDefaultCertificate": true},
  "Origins": {"Quantity": 3, "Items": [
    {"Id": "web-s3", "DomainName": "$WEB_BUCKET.s3.$REGION.amazonaws.com",
     "OriginAccessControlId": "$oac", "S3OriginConfig": {"OriginAccessIdentity": ""}},
    $(api_origin auth-ec2 8001),
    $(api_origin task-ec2 8002)
  ]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "web-s3",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"], "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "FunctionAssociations": {"Quantity": 1, "Items": [{"FunctionARN": "$fn_arn", "EventType": "viewer-request"}]}
  },
  "CacheBehaviors": {"Quantity": 2, "Items": [
    $(api_behavior '/api/auth/*' auth-ec2),
    $(api_behavior '/api/tasks*' task-ec2)
  ]}
}
EOF
)
    dist_id=$(aws cloudfront create-distribution --distribution-config "$config" --query Distribution.Id --output text)
    ok "created distribution $dist_id (takes 5-10 minutes to deploy worldwide)"
  fi

  dist_arn="arn:aws:cloudfront::$ACCOUNT_ID:distribution/$dist_id"
  aws s3api put-bucket-policy --bucket "$WEB_BUCKET" --policy "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{\"Sid\":\"AllowCloudFrontOAC\",\"Effect\":\"Allow\",
      \"Principal\":{\"Service\":\"cloudfront.amazonaws.com\"},
      \"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$WEB_BUCKET/*\",
      \"Condition\":{\"StringEquals\":{\"AWS:SourceArn\":\"$dist_arn\"}}}]}"
  ok "web bucket readable only by this distribution"
  ok "URL: https://$(aws cloudfront get-distribution --id "$dist_id" --query Distribution.DomainName --output text)"
}

step_github() {
  log "github: OIDC provider + deploy role"
  : "${GITHUB_REPO:?set GITHUB_REPO=owner/name}"
  local provider_arn="arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
  local id dist_id
  if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" >/dev/null 2>&1; then
    aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
      --client-id-list sts.amazonaws.com --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
    ok "created OIDC provider"
  else ok "OIDC provider exists"; fi

  # Only workflows running on the main branch of this one repository can assume the role.
  local trust="{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Federated\":\"$provider_arn\"},
      \"Action\":\"sts:AssumeRoleWithWebIdentity\",
      \"Condition\":{
        \"StringEquals\":{\"token.actions.githubusercontent.com:aud\":\"sts.amazonaws.com\",
                          \"token.actions.githubusercontent.com:sub\":\"repo:$GITHUB_REPO:ref:refs/heads/main\"}}}]}"
  if ! aws iam get-role --role-name "$P-github-deploy" >/dev/null 2>&1; then
    aws iam create-role --role-name "$P-github-deploy" --assume-role-policy-document "$trust" >/dev/null
    ok "created role $P-github-deploy (trusts repo:$GITHUB_REPO:ref:refs/heads/main)"
  else
    aws iam update-assume-role-policy --role-name "$P-github-deploy" --policy-document "$trust"
    ok "role exists, trust policy updated for $GITHUB_REPO"
  fi

  id=$(instance_id); dist_id=$(distribution_id)
  has "$id" && has "$dist_id" || { echo "Run the ec2 and cloudfront steps first" >&2; exit 1; }
  aws iam put-role-policy --role-name "$P-github-deploy" --policy-name "$P-deploy" --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":\"ecr:GetAuthorizationToken\",\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"ecr:BatchCheckLayerAvailability\",\"ecr:BatchGetImage\",
        \"ecr:GetDownloadUrlForLayer\",\"ecr:InitiateLayerUpload\",\"ecr:UploadLayerPart\",
        \"ecr:CompleteLayerUpload\",\"ecr:PutImage\"],
       \"Resource\":\"arn:aws:ecr:$REGION:$ACCOUNT_ID:repository/$P/*\"},
      {\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",
       \"Resource\":[\"arn:aws:s3:::$WEB_BUCKET\",\"arn:aws:s3:::$DEPLOY_BUCKET\"]},
      {\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\",\"s3:DeleteObject\"],
       \"Resource\":[\"arn:aws:s3:::$WEB_BUCKET/*\",\"arn:aws:s3:::$DEPLOY_BUCKET/*\"]},
      {\"Effect\":\"Allow\",\"Action\":[\"cloudfront:CreateInvalidation\",\"cloudfront:GetInvalidation\"],
       \"Resource\":\"arn:aws:cloudfront::$ACCOUNT_ID:distribution/$dist_id\"},
      {\"Effect\":\"Allow\",\"Action\":\"ssm:SendCommand\",
       \"Resource\":[\"arn:aws:ec2:$REGION:$ACCOUNT_ID:instance/$id\",
                     \"arn:aws:ssm:$REGION::document/AWS-RunShellScript\"]},
      {\"Effect\":\"Allow\",\"Action\":[\"ssm:GetCommandInvocation\",\"ssm:ListCommandInvocations\"],\"Resource\":\"*\"}
    ]}"
  ok "deploy permissions: ECR push ($P/*), S3 web+deploy, invalidate $dist_id, SSM on $id only"
}

step_bootstrap() {
  log "bootstrap: RDS databases + EC2 .env"
  local id endpoint secret
  id=$(instance_id); has "$id" || { echo "Run the ec2 step first" >&2; exit 1; }

  ok "waiting for RDS to be available (can take ~10 minutes after creation)"
  aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
  endpoint=$(rds_field Endpoint.Address)
  secret=$(rds_field MasterUserSecret.SecretArn)
  ok "RDS endpoint $endpoint"

  ok "waiting for the instance to register with SSM"
  for _ in $(seq 1 60); do
    [ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" \
      --query 'InstanceInformationList[0].PingStatus' --output text)" = "Online" ] && break
    sleep 10
  done

  aws s3 sync deploy/ "s3://$DEPLOY_BUCKET/deploy/" --exclude 'aws/*' --exclude 'cloudfront/*' --delete >/dev/null
  ok "uploaded compose file + scripts to s3://$DEPLOY_BUCKET/deploy/"

  ./deploy/aws/ssm-run.sh "$id" "$REGION" 600 "bootstrap" \
    "for i in \$(seq 1 60); do [ -f /var/lib/cloud/taskmanager-bootstrap-done ] && break; sleep 5; done" \
    "aws s3 sync s3://$DEPLOY_BUCKET/deploy/ /opt/taskmanager/ --region $REGION --only-show-errors" \
    "bash /opt/taskmanager/ec2/make-env.sh $endpoint $ECR_REGISTRY $REGION $secret" \
    "bash /opt/taskmanager/rds/init-db.sh"
}

step_outputs() {
  log "outputs: GitHub repository variables"
  local id dist_id domain role_arn
  id=$(instance_id); dist_id=$(distribution_id)
  domain=$(has "$dist_id" && aws cloudfront get-distribution --id "$dist_id" --query Distribution.DomainName --output text || echo None)
  role_arn=$(aws iam get-role --role-name "$P-github-deploy" --query Role.Arn --output text 2>/dev/null || echo None)
  mkdir -p deploy/aws/.out
  cat > deploy/aws/.out/github-variables.env <<EOF
AWS_REGION=$REGION
AWS_ROLE_ARN=$role_arn
ECR_REGISTRY=$ECR_REGISTRY
EC2_INSTANCE_ID=$id
DEPLOY_BUCKET=$DEPLOY_BUCKET
WEB_BUCKET=$WEB_BUCKET
CF_DISTRIBUTION_ID=$dist_id
CF_DOMAIN=$domain
EOF
  cat deploy/aws/.out/github-variables.env
  echo
  echo "Add each line above in GitHub: repo → Settings → Secrets and variables → Actions → Variables tab"
  echo "(they are not secrets; no AWS keys are stored in GitHub). Saved to deploy/aws/.out/github-variables.env"
  echo "Live URL: https://$domain"
}

case "${1:-}" in
  network) step_network ;;
  rds) step_rds ;;
  ecr) step_ecr ;;
  buckets) step_buckets ;;
  iam-ec2) step_iam_ec2 ;;
  ec2) step_ec2 ;;
  cloudfront) step_cloudfront ;;
  github) step_github ;;
  bootstrap) step_bootstrap ;;
  outputs) step_outputs ;;
  all)
    step_network; step_rds; step_ecr; step_buckets; step_iam_ec2; step_ec2
    step_cloudfront; step_github; step_bootstrap; step_outputs ;;
  *) sed -n '2,22p' "$0"; exit 2 ;;
esac
