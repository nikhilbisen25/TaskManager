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

<!-- Next entries: AWS deploy + CI, rehearsed live changes (prompt, plan corrections, time to live). -->
