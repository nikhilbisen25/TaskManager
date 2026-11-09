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
| Secrets in a **root-only `.env` on EC2** | Simple; never in git or GitHub | SSM Parameter Store / Secrets Manager |
| **Migrations run on container start** (Alembic, Flyway) | A deploy that adds a column (e.g. live "priority" change) needs no manual DB step | A separate migration job before the rollout |

## Files I'll add to the repo

| File | Purpose |
|---|---|
| `deploy/docker-compose.prod.yml` | Backends only, images `${ECR}/…:${TAG}`, env from `/opt/taskmanager/.env`, `restart: unless-stopped` |
| `deploy/ec2/user-data.sh` | First boot: install Docker + compose plugin, 1 GB swap, `/opt/taskmanager` |
| `deploy/ec2/deploy.sh <sha>` | ECR login → pull → `up -d` → wait for both health checks → print result (non-zero exit on failure) |
| `deploy/rds/init.sql` | Creates `authdb`/`taskdb`, their users and grants (run once from EC2 with a `postgres` container) |
| `deploy/cloudfront/spa-rewrite.js` | CloudFront Function: `/login`, `/register` etc. → `/index.html`, leaves files alone |
| `deploy/aws/setup.sh` | AWS CLI script that creates the resources in order (each step re-runnable), prints the CloudFront URL |
| `deploy/aws/teardown.sh` | Deletes everything after the interview process (stops costs) |
| `.github/workflows/ci.yml` | On PRs/pushes: pytest, `mvnw test`, frontend build, in parallel |
| `.github/workflows/deploy.yml` | On push to `main` (+ manual button): tests → build changed images (Buildx + GHA cache) → ECR → SSM deploy → S3 sync + invalidation → `smoke-test.sh` against the live URL |

## Pipeline timing budget (target ≤ 5 min push → live)

| Stage | Estimate | How |
|---|---|---|
| Tests (3 parallel jobs) | ~1.5 min | Maven/pip/npm caches |
| Build + push task-service image | ~1.5-2 min | Buildx layer cache; only services whose folder changed are rebuilt |
| Frontend build + S3 sync + invalidation | ~1 min | runs in parallel with the image build |
| EC2 pull + restart + health wait | ~1-1.5 min | Spring Boot cold start on t3.micro is the slowest part |
| Live smoke test | ~10 s | `scripts/smoke-test.sh https://dxxxx.cloudfront.net` |

We'll measure the real number on Wednesday and rehearse against it on Thursday.

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
6. Choose the **RDS master password** yourself when prompted (it is typed into the AWS CLI prompt or
   console, not into chat).

**Me:** write all files above, run the setup with your approval at each step, wire up the GitHub
OIDC role and the workflow, measure the push-to-live time, update README/CLAUDE.md/AI_USAGE.md.

## Order of work (Wednesday)

1. Push repo to GitHub → CI workflow green (proves tests run in the cloud).
2. `setup.sh`: VPC default + security groups → RDS (takes ~10 min, so start it first) → ECR repos →
   EC2 with instance role + user-data + Elastic IP → S3 bucket → CloudFront (OAC, function, 3 behaviours)
   → GitHub OIDC provider + deploy role.
3. Once RDS is up: run `init.sql` via SSM, write `/opt/taskmanager/.env` on EC2.
4. First deploy via the workflow → `smoke-test.sh` against the CloudFront URL → UI check.
5. Make a trivial change, push, time it. Then document the URL + timing.

## Risks and fallbacks for the live session

| Risk | Mitigation |
|---|---|
| Pipeline fails on the call | `workflow_dispatch` re-run; manual fallback: `deploy.sh` via Session Manager with an image built from the last good SHA |
| Bad deploy | Redeploy the previous SHA (one command); Flyway migrations are additive only |
| EC2 cold or out of credits | Warm it up Friday morning; t3 unlimited mode is on by default |
| CloudFront still serving old JS | Invalidation of `/index.html` + hashed asset names; hard refresh |
| Authorization header not forwarded by CloudFront | API behaviours use the managed `CachingDisabled` + `AllViewerExceptHostHeader` policies; the smoke test checks 401 vs 200 right after setup |
