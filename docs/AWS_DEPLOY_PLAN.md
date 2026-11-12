# AWS deployment plan (Task 2)

Goal: a public HTTPS URL for the app, and a `git push` that reaches it within about 5 minutes,
reliable enough to run live during the interview.

## Target architecture

```
                 https://dxxxx.cloudfront.net   (CloudFront default certificate, HTTP→HTTPS redirect)
Browser ───────► CloudFront
                   ├── default (/*)        → S3 bucket (private, Origin Access Control)
                   │                          + CloudFront Function: SPA paths → /index.html
                   ├── /api/auth/*         → EC2 origin, HTTP :8001  (caching disabled)
                   └── /api/tasks*         → EC2 origin, HTTP :8002  (caching disabled)

EC2 t3.micro (Amazon Linux 2023, Elastic IP, Docker + compose, 1 GB swap)
   auth-service :8001  ─┐
   task-service :8002  ─┴──► RDS PostgreSQL 16, db.t3.micro, private
                              one instance, two databases: authdb (user auth), taskdb (user task)

GitHub Actions ──OIDC (no stored AWS keys)──► IAM role
   build images → ECR → SSM Run Command on EC2: deploy.sh <git-sha>
   npm run build → aws s3 sync → CloudFront invalidation
```

Region: **ap-south-1 (Mumbai)**, the closest region to you, so the live demo stays responsive.

## Decisions and why (talking points)

| Decision | Why | Upgrade path / trade-off |
|---|---|---|
| **EC2 + Docker Compose** for backends (not ECS) | Same compose model as local; one small box; quick to debug live | ECS Fargate + ALB: no servers to manage, rolling deploys, costs more |
| **One RDS instance, two databases** | Cost/free-tier; still one database and one DB user per service | One instance per service for full isolation |
| **CloudFront in front of everything** | One HTTPS origin: no CORS, no mixed content (HTTPS page calling an HTTP API) | Custom domain + ACM cert; ALB with HTTPS to the backends |
| CloudFront → EC2 over **HTTP** | No domain or cert needed for EC2 | Encrypt that hop too: ALB + ACM, or a custom domain on the origin |
| **Security group allows only CloudFront** (AWS managed prefix list `com.amazonaws.global.cloudfront.origin-facing`, one rule for ports 8001-8002) | Backends can't be reached directly from the internet, bypassing CloudFront | Also verify a secret origin header |
| **No SSH: SSM Session Manager + Run Command** | Port 22 stays closed; no SSH keys in GitHub; console shell access for debugging | n/a |
| **GitHub OIDC → IAM role** | No long-lived AWS keys stored in GitHub; role limited to ECR push, S3 sync, invalidation, SSM send-command | n/a |
| **ECR** for images (instead of GHCR) | The EC2 instance role pulls with no token; everything stays in AWS | GHCR works too, but needs public packages or a PAT on EC2 |
| Images tagged with the **git SHA** | Every deploy is traceable; rollback = redeploy the previous SHA | n/a |
| **RDS master password managed by RDS in Secrets Manager** (`--manage-master-user-password`) | Nobody types or sees it; the EC2 role reads it once to create the app users | n/a |
| App secrets (JWT secret, DB user passwords) **generated on the EC2 instance** into a root-only `.env` | They never pass through a laptop, GitHub or chat; never in git | SSM Parameter Store / Secrets Manager for app secrets too |
| **Migrations run on container start** (Alembic, Flyway) | A deploy that adds a column (e.g. live "priority" change) needs no manual DB step | A separate migration job before the rollout |

## Files in the repo

| File | Purpose |
|---|---|
| `deploy/docker-compose.prod.yml` | Backends only, images `${ECR_REGISTRY}/taskmanager/<svc>:<sha>`, RDS over SSL, `restart: unless-stopped`, memory limits |
| `deploy/ec2/user-data.sh` | First boot: Docker + compose plugin, 1 GB swap, `/opt/taskmanager` |
| `deploy/ec2/make-env.sh` | Writes `/opt/taskmanager/.env`; generates secrets on the instance; re-runs keep them |
| `deploy/ec2/deploy.sh` | `deploy.sh auth=<sha> task=<sha>` · `deploy.sh rollback`: ECR login → pull → `up -d --wait` (fails if unhealthy, prints logs) |
| `deploy/rds/init.sql`, `init-db.sh` | Creates `authdb`/`taskdb` + users, each user can connect only to its own DB; reads the master secret with the instance role |
| `deploy/cloudfront/spa-rewrite.js` | CloudFront Function: `/login`, `/register` etc. → `/index.html`, leaves files alone |
| `deploy/aws/setup.sh <step>` | AWS CLI, one re-runnable step at a time: `network rds ecr buckets iam-ec2 ec2 cloudfront github bootstrap outputs` |
| `deploy/aws/ssm-run.sh` | Runs commands on EC2 via SSM Run Command and waits (used by setup and the workflow) |
| `deploy/aws/teardown.sh --yes-delete-everything` | Deletes everything after the interview process (stops costs) |
| `.github/workflows/ci.yml` | On PRs/branch pushes (and called by deploy): pytest, `mvnw test`, frontend build, in parallel |
| `.github/workflows/deploy.yml` | On push to `main` (+ "Run workflow" button): tests ‖ build changed images (Buildx + GHA cache) → ECR → SSM deploy; frontend → S3 + invalidation; then `smoke-test.sh` against the live URL |

A small private **deploy bucket** carries the compose file and scripts to the instance (the workflow
syncs it, EC2 pulls it), so infrastructure files are versioned in git like the code.

## Pipeline timing budget (target ≤ 5 min push → live)

| Stage | Estimate | How |
|---|---|---|
| Tests (3 parallel jobs) | ~1.5 min | Maven/pip/npm caches |
| Build + push task-service image | ~1.5-2 min | Buildx layer cache; only services whose folder changed are rebuilt |
| Frontend build + S3 sync + invalidation | ~1 min | runs in parallel with the image build |
| EC2 pull + restart + health wait | ~1-1.5 min | Spring Boot cold start on t3.micro is the slowest part |
| Live smoke test | ~10 s | `scripts/smoke-test.sh https://dxxxx.cloudfront.net` |

**Measured on 2026-11-12:**

| Change | Push → live | Notes |
|---|---|---|
| Frontend only (footer build stamp) | **82 s** | tests ‖ S3 upload + invalidation, smoke test; image builds skipped |
| Everything, cold cache ("Run workflow") | **3 min 25 s** | task-service image build 126 s was the long pole |
| Backend + frontend, warm cache (e.g. priority + due date) | ~2.5-3 min expected | build-task with cached Maven layer + 50 s EC2 rollout |

## Cost (ap-south-1, approximate, check the AWS pricing pages)

| Item | ≈ per month if left running |
|---|---|
| EC2 t3.micro | ~$8 |
| RDS db.t3.micro + 20 GB storage | ~$15 |
| Public IPv4 (Elastic IP) | ~$3.6 |
| ECR, S3, CloudFront, SSM | under $1 at this traffic |
| **Total** | **~$25-30 / month** (about ₹2,200-2,600) |

New AWS accounts get free-tier usage or sign-up credits that should cover this for the interview
week. Confirm what your account has under **Billing → Free Tier / Credits**. A ₹500 budget alert may
fire on *gross* usage even when credits cover it; that's fine, it's an early warning. Run
`teardown.sh` once the process is over.

## Who does what

**You** (accounts, passwords, MFA, payment are always yours):
1. Create/sign in to the AWS account, turn on MFA for the root user, set a **₹500 budget alert**
   (Billing → Budgets → "Monthly cost budget").
2. Create an IAM user (or IAM Identity Center user) with admin rights for setup, so the root
   user isn't used day to day.
3. Install **AWS CLI v2** (Windows MSI from aws.amazon.com/cli) and run `aws configure` (or
   `aws configure sso`) yourself, with region `ap-south-1`. I never see or type the keys.
4. Create the **empty GitHub repo** and tell me its name. I add the remote; I push only when you say so.
5. Approve each resource-creating step when I run `setup.sh` (it costs money, so it goes step by step).
   No database password to choose: RDS generates and stores the master password in Secrets Manager.
6. Add the 8 values printed by `setup.sh outputs` as **GitHub Actions variables** (repo → Settings →
   Secrets and variables → Actions → Variables). They are not secrets.

**Me:** write all files above, run the setup with your approval at each step, wire up the GitHub
OIDC role and the workflow, measure the push-to-live time, update README/CLAUDE.md/AI_USAGE.md.

## Order of work (Wednesday)

1. Push repo to GitHub. The Deploy workflow will fail until AWS exists; that's expected.
2. From Git Bash in the repo root (`GITHUB_REPO=owner/name` set):
   ```bash
   ./deploy/aws/setup.sh network      # security groups
   ./deploy/aws/setup.sh rds          # starts RDS creation first: it takes ~10 min
   ./deploy/aws/setup.sh ecr
   ./deploy/aws/setup.sh buckets
   ./deploy/aws/setup.sh iam-ec2
   ./deploy/aws/setup.sh ec2
   ./deploy/aws/setup.sh cloudfront
   ./deploy/aws/setup.sh github
   ./deploy/aws/setup.sh bootstrap    # waits for RDS, writes .env on EC2, creates both databases
   ./deploy/aws/setup.sh outputs      # values for the GitHub variables + the live URL
   ```
3. Add the GitHub variables → Actions → Deploy → **Run workflow** (first deploy builds everything).
4. Smoke test runs at the end of the workflow; then a UI check in the browser.
5. Make a trivial change, push, time it. Then document the URL + timing.

## Risks and fallbacks for the live session

| Risk | Mitigation |
|---|---|
| Pipeline fails on the call | `workflow_dispatch` re-run; manual fallback: `deploy.sh` via Session Manager with an image built from the last good SHA |
| Bad deploy | Redeploy the previous SHA (one command); Flyway migrations are additive only |
| EC2 cold or out of credits | Warm it up Friday morning; t3 unlimited mode is on by default |
| CloudFront still serving old JS | Invalidation of `/index.html` + hashed asset names; hard refresh |
| Authorization header not forwarded by CloudFront | API behaviours use the managed `CachingDisabled` + `AllViewerExceptHostHeader` policies; the smoke test checks 401 vs 200 right after setup |
