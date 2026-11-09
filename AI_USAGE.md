# AI usage log

The brief encourages AI assistants. This log records what I asked the AI to do, what it produced,
and what I reviewed, corrected or decided myself. Tool: **Claude Code** (Anthropic), run in this repo
with `CLAUDE.md` as standing project context.

## How I work with the AI

1. **Context → goal → constraints → acceptance → "plan first".** Every non-trivial prompt names the
   affected service/files, the requirement in one sentence, what must not change (JWT contract, paths),
   and how we'll know it works (tests, smoke script, UI behaviour).
2. Read the plan, correct it, then let it implement.
3. Review the diff myself, run the tests and `scripts/smoke-test.sh`, then commit and push.
4. `CLAUDE.md` holds architecture, conventions and a "how to add a field" recipe, so short prompts
   still produce code that fits the project.

## Log

### 2026-11-09: Strategy and architecture (before any code)

- Prompt (summary): "Here is the Zifo brief (PDF). Plan how to build and deploy it in 4 days on a
  weak laptop, and how to be ready to live-modify and redeploy during the interview."
- Decisions I made with the AI's input:
  - Task Service in **Spring Boot** (allowed by the brief; my core stack; polyglot proves service independence).
  - **HS256 shared-secret JWT**, verified locally by task-service. RS256/JWKS noted as the upgrade.
  - **Database per service**; one RDS instance with two databases in AWS (free-tier trade-off).
  - **One origin via CloudFront** routing `/api/*` to EC2: avoids mixed content and CORS.
  - **GitHub Actions builds the images**, so neither my laptop nor a small EC2 compiles Java on the call.

### 2026-11-09: Scaffold all three services + docker-compose (Task 1)

- Prompt (summary): build auth-service (FastAPI, SQLAlchemy, Alembic, bcrypt, HS256 JWT with
  `sub`/`email`/`exp`, pytest), task-service (Java 21, Spring Boot 3.x, JPA, Flyway, Spring Security
  verifying the JWT only, `ownerId` from the token, ProblemDetail errors, `@WebMvcTest` + Mockito tests),
  React + Vite + Tailwind frontend (Login, Register, Dashboard with status filter), compose with two
  Postgres containers and healthchecks, plus CLAUDE.md / README / this file.
- Things the AI caught or decided during implementation (and I checked):
  - Spring Initializr now defaults to Boot 4.x; pinned the parent to **Spring Boot 3.5.16** to match the brief.
  - **passlib 1.7.4 is incompatible with bcrypt ≥ 4.1**, so bcrypt is pinned to 4.0.1, and passwords are
    capped at 72 bytes (bcrypt's limit) in the Pydantic schema.
  - Used Spring's **OAuth2 resource server** with `NimbusJwtDecoder.withSecretKey(...)` instead of a
    hand-written JWT filter: less code, and moving to RS256/JWKS becomes a one-line change.
  - Added a **JWT contract test**: tokens minted by PyJWT are verified by the Spring decoder
    (valid, expired, wrong secret), so a change on either side that breaks the contract fails the build.
  - Declarative `Base` moved to `app/base.py` so Alembic can import models without needing `JWT_SECRET`.
  - Mockito `delete(any())` was ambiguous (`JpaSpecificationExecutor` also has `delete(Specification)`);
    fixed to `any(Task.class)`.
  - Paged results returned as an explicit `PageResponse` record rather than serialising Spring's `Page`.
  - Another user's task returns **404, not 403**, so task ids can't be probed.
- Verified: auth-service 7 pytest tests pass, task-service 12 JUnit tests pass, frontend type-checks
  and builds, auth-service boots and runs register → login → `/me` natively.

### 2026-11-09: First `docker compose up --build` (Task 1 verified)

- Prompt (summary): "Docker is installed: build and start the stack, then verify end to end."
- All 3 images built first time and all 5 containers reported healthy, with no code changes needed.
- `scripts/smoke-test.sh` passed through nginx on :8080 (register, login, 401 without token, create,
  list with filter, update, status change, delete).
- The AI then drove the real UI in a browser: register → login → create 2 tasks → change status →
  filter "Done" → edit (description + status) → delete. No console errors.
- Memory with everything running: about 355 MB total (task-service about 200 MB, under its 512 MB limit).
- Local demo user is recorded in `.env.example` (test-only values).

### 2026-11-09: AWS deployment plan and infrastructure scripts (Task 2 prep)

- Prompt (summary): "Plan the AWS deploy (EC2 + RDS + S3/CloudFront, push-to-live ≤ 5 min), then write
  every file needed before I have AWS access." Plan: `docs/AWS_DEPLOY_PLAN.md`.
- Decisions from the planning step (I reviewed and accepted):
  - **GitHub OIDC** instead of AWS access keys in GitHub; **SSM Run Command** instead of SSH (port 22 closed).
  - **ECR** instead of GHCR, so EC2 pulls with its instance role and needs no registry token.
  - **RDS-managed master password** in Secrets Manager; app secrets generated on the instance itself.
  - Security group allows only the **CloudFront origin-facing prefix list**, as one rule for ports
    8001-8002 (two prefix-list rules would exceed the default 60-rule quota).
- Problems caught while writing:
  - BuildKit cache mounts in the task-service Dockerfile aren't kept by the GitHub Actions layer cache,
    so every CI build would re-download all Maven deps; moved them into a normal cached layer.
  - On RDS the master user isn't a superuser: `CREATE DATABASE ... OWNER auth` needs membership, so
    `init.sql` grants the role to itself first. Tested against Postgres 16 as a non-superuser with
    CREATEROLE/CREATEDB, run twice (idempotent), and checked each user can't connect to the other DB.
  - Git Bash rewrites arguments like `/aws/service/...` into Windows paths; scripts set `MSYS_NO_PATHCONV=1`.
- Verified locally: all scripts pass `bash -n`; workflows and compose files parse; prod compose
  interpolation checked with dummy values; CloudFront function tested with node; distribution JSON parses.
  **Not yet run against AWS.**

<!-- Next entries: AWS deploy + CI, rehearsed live changes (prompt, plan corrections, time to live). -->
