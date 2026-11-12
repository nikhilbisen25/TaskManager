# CLAUDE.md: project guide for AI assistants

Task Management App built as microservices for the Zifo hands-on exercise.
Read this first; it is kept short on purpose so short prompts work.
Deep dive (every file, flows, decisions, debug history): `docs/PROJECT_GUIDE.md`.

## Architecture

| Service | Stack | Port | DB | Path prefix |
|---|---|---|---|---|
| `auth-service/` | Python 3.12, FastAPI, SQLAlchemy 2, Alembic, Pydantic v2, passlib/bcrypt, PyJWT | 8001 | `authdb` (Postgres 16) | `/api/auth` |
| `task-service/` | Java 21, Spring Boot 3.5, Spring Data JPA, Flyway, Spring Security resource server | 8002 | `taskdb` (Postgres 16) | `/api/tasks` |
| `frontend/` | React 19, Vite, TypeScript, TailwindCSS v4, Axios, React Router | 5173 dev / 80 in nginx | none | `/` |

- **Single origin.** The browser only talks to one origin and calls relative `/api/...`.
  Locally: nginx in the `frontend` container (http://localhost:8080) or the Vite dev proxy.
  AWS: CloudFront routes `/api/auth/*` and `/api/tasks*` to the backends, everything else to S3.
  Services keep the full `/api/...` path (no prefix stripping anywhere).
- **JWT contract** (do not change casually, both services depend on it):
  HS256, secret = env `JWT_SECRET` (>= 32 chars, same value in both services),
  claims `sub` = user id (UUID string), `email`, `iat`, `exp`.
  auth-service *issues*; task-service only *verifies* locally (`SecurityConfig.jwtDecoder`), with no
  runtime call to auth-service. Upgrade path: RS256 + JWKS endpoint, `NimbusJwtDecoder.withJwkSetUri`.
  `task-service/.../config/JwtContractTest.java` pins this contract with tokens minted by PyJWT.
- **Database per service.** No cross-DB foreign keys; `tasks.owner_id` is just the JWT `sub`.
- **Ownership.** `ownerId` always comes from the token (`@AuthenticationPrincipal Jwt`), never from a
  request body. Another user's task returns 404 (not 403) so existence isn't leaked.

## Endpoints

auth-service: `POST /api/auth/register` {email, password(8-72), full_name?} → 201 user ·
`POST /api/auth/login` {email, password} → {access_token, token_type, expires_in} ·
`GET /api/auth/me` (Bearer) · `GET /api/auth/health` · Swagger UI `/api/auth/docs`.
Errors: FastAPI `{"detail": ...}` (409 duplicate email, 401 bad credentials, 422 validation).

task-service (all need Bearer): `GET /api/tasks?status=&page=&size=&sort=createdAt,desc` → PageResponse
`{content, page, size, totalElements, totalPages}` · `GET /api/tasks/{id}` · `POST /api/tasks` →
201 + Location · `PUT /api/tasks/{id}` (full update) · `PATCH /api/tasks/{id}/status` {status} ·
`DELETE /api/tasks/{id}` → 204 · `GET /actuator/health` (public).
Errors: RFC 9457 `ProblemDetail` (`application/problem+json`); validation errors carry `errors: {field: msg}`.

## Code layout and conventions

**task-service** (`com.zifo.taskservice`): feature package `task/` holds `Task` (entity),
`TaskStatus`, `TaskRepository` (JPA + `JpaSpecificationExecutor`), `TaskSpecifications` (one static
method per filter; a null arg means "no filter"), `TaskService` (business logic, `@Transactional`,
owner-scoped), `TaskController` (thin), `dto/TaskDtos` (records: requests, `TaskResponse.from`,
`PageResponse`). `web/GlobalExceptionHandler` maps exceptions to ProblemDetail. `config/SecurityConfig`.
Schema changes = **new Flyway file** `src/main/resources/db/migration/V{n}__desc.sql`
(never edit an applied one); Hibernate runs with `ddl-auto=validate`.
Constructor injection, no Lombok, records for DTOs.

**auth-service** (`app/`): `main.py` (app), `routers/auth.py` (endpoints), `schemas.py` (Pydantic),
`models.py` (SQLAlchemy), `security.py` (bcrypt + JWT), `deps.py` (`get_current_user`), `config.py`
(pydantic-settings from env), `base.py` (Declarative Base, importable without env).
Schema changes = new Alembic revision in `alembic/versions/`. Migrations run on container start.

**frontend** (`src/`): `types.ts` (mirrors backend DTOs), `api/client.ts` (Axios instance, Bearer
interceptor, 401 → logout, `errorMessage()` for FastAPI + ProblemDetail errors), `api/auth.ts`,
`api/tasks.ts`, `auth/AuthContext.tsx` (token in localStorage, user via `/me`),
`pages/{Login,Register,Dashboard}Page.tsx`, `components/TaskForm.tsx` (create + edit), `components/ui.tsx`
(Tailwind building blocks: `Button`, `Field`, `StatusBadge`, ...). Plain Tailwind utility classes.

## Recipe: adding a task field / filter (e.g. priority + due date)

1. `task-service`: new Flyway migration `V2__...sql` → field on `Task` → add to `TaskDtos` requests and
   `TaskResponse` → spec in `TaskSpecifications` + `@RequestParam` in `TaskController.list` and
   `TaskService.list` → update `TaskControllerTest`/`TaskServiceTest`.
2. `frontend`: `types.ts` → `api/tasks.ts` (`TaskQuery` + params) → `TaskForm.tsx` input →
   badge/filter control in `DashboardPage.tsx`.
3. auth-service and the JWT contract are untouched.

## Run, test, build

```bash
cp .env.example .env              # once; set JWT_SECRET
docker compose up --build         # http://localhost:8080 (nginx) · :8001/api/auth/docs · :8002/actuator/health
./scripts/smoke-test.sh           # API end-to-end check (also takes a base URL, e.g. the CloudFront URL)
```

Native (no Docker) on this Windows laptop:

```bash
# auth-service
cd auth-service && python -m venv .venv && .venv/Scripts/pip install -r requirements-dev.txt
.venv/Scripts/python -m pytest -q
# task-service (default `java` on PATH is Java 8, so point at JDK 21)
cd task-service && JAVA_HOME="/c/Users/Dell/.jdks/ms-21.0.11" ./mvnw -B test
# frontend
cd frontend && npm install && npm run build      # npm run dev → http://localhost:5173 (proxies /api)
```

Env vars: `JWT_SECRET`, `JWT_EXPIRE_MINUTES` (auth) · auth `DATABASE_URL`
(`postgresql+psycopg://user:pw@host:5432/authdb`) · task `DB_URL` (`jdbc:postgresql://host:5432/taskdb`),
`DB_USERNAME`, `DB_PASSWORD`, `PORT`. Compose builds these from `.env` (see `.env.example`).
Never commit `.env` or real secrets.

## Deploy (AWS ap-south-1; full plan in docs/AWS_DEPLOY_PLAN.md)

**Deploying a change = commit + `git push` to `main`.** `.github/workflows/deploy.yml` runs tests and
builds only the changed service images (ECR, tag = git SHA) in parallel, runs `deploy/ec2/deploy.sh`
on EC2 through SSM (no SSH), uploads the frontend to S3 + invalidates CloudFront, then runs
`scripts/smoke-test.sh` against `https://$CF_DOMAIN`. Config = GitHub repo *variables*; auth = OIDC role.

- EC2 t3.micro: `/opt/taskmanager/{docker-compose.prod.yml, .env, tags.env, ec2/, rds/}`; backends
  only (8001/8002, reachable from CloudFront only). Rollback: `bash /opt/taskmanager/ec2/deploy.sh rollback`
  via Session Manager.
- RDS Postgres 16 (one instance, `authdb` + `taskdb`, SSL required). Migrations run on container start,
  so a schema change just needs its Alembic/Flyway file.
- CloudFront: default → S3 (SPA rewrite function), `/api/auth/*` → EC2:8001, `/api/tasks*` → EC2:8002.
- Infra changes: `deploy/aws/setup.sh <step>` (re-runnable); `deploy/aws/teardown.sh` deletes everything.

## Working rules for the AI

- Plan first for multi-file changes; keep the layering (controller → service → repository, DTOs at the edge).
- Every schema change ships with a migration; keep existing tests green and add one for new behaviour.
- Don't change the JWT contract or the `/api/...` paths without saying so explicitly.
- Log notable prompts/decisions in `AI_USAGE.md`.
