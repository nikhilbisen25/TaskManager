# Task Manager: microservices demo

A small task management app: users register, log in, and manage their own tasks.
Built as two independently deployable services plus a React SPA.

```
                         ┌────────────── one public origin ──────────────┐
                         │  local:  nginx  (http://localhost:8080)       │
 Browser ── HTTP(S) ───► │  AWS:    CloudFront (https://xxxx.cloudfront.net)
                         └───┬──────────────────┬──────────────────┬─────┘
                             │ /*               │ /api/auth/*      │ /api/tasks*
                             ▼                  ▼                  ▼
                    React + Vite + Tailwind   auth-service        task-service
                    (static files; S3 in AWS) FastAPI · :8001     Spring Boot · :8002
                                              registers users,    task CRUD, verifies JWT
                                              issues HS256 JWT    locally (no call to auth)
                                                    │                  │
                                                    ▼                  ▼
                                              Postgres authdb     Postgres taskdb
                                              (RDS in AWS: one instance, two databases)

            JWT contract:  HS256 · shared JWT_SECRET · claims sub=userId, email, iat, exp
```

## Key design decisions

- **Polyglot services, one contract.** Auth in Python/FastAPI (as required), tasks in Java/Spring Boot.
  They share nothing but the JWT format, so either can be rewritten or redeployed alone.
- **Local JWT verification.** task-service validates signature and expiry itself (Spring Security
  OAuth2 resource server). If auth-service is down, existing sessions keep working; only new logins fail.
  Next step for production: RS256 + a JWKS endpoint so only auth-service holds the signing key.
- **Database per service.** `authdb` and `taskdb`; no cross-service foreign keys. In AWS both live on
  one RDS instance (cost) but stay logically separate (own database, own user).
- **Ownership from the token.** `ownerId` is the JWT `sub`; it is never accepted from the request body.
  Another user's task returns 404.
- **Single origin.** The SPA calls relative `/api/...`; nginx (local) or CloudFront (AWS) routes it.
  This avoids CORS and the HTTPS-page-calls-HTTP-API mixed-content trap.
- **Schema migrations** owned by each service: Alembic (auth) and Flyway (tasks); Hibernate only validates.
- **Errors**: task-service returns RFC 9457 ProblemDetail; the UI shows field-level messages.

## Run locally (Task 1)

Prerequisite: Docker Desktop (WSL2 backend on Windows).

```bash
cp .env.example .env        # then set a long random JWT_SECRET
docker compose up --build   # or: docker-compose up --build
```

| URL | What |
|---|---|
| http://localhost:8080 | the app (Register → Login → Dashboard) |
| http://localhost:8001/api/auth/docs | auth-service Swagger UI |
| http://localhost:8002/actuator/health | task-service health |

API end-to-end check (Git Bash / Linux / macOS):

```bash
./scripts/smoke-test.sh                 # defaults to http://localhost:8080
```

Stop with `Ctrl+C`; `docker compose down -v` also deletes the database volumes.

On an 8 GB Windows machine, cap WSL2 memory first: create `%UserProfile%\.wslconfig` with
`[wsl2]` / `memory=3GB` / `processors=2`, then run `wsl --shutdown` and restart Docker Desktop.

### Without Docker (development)

```bash
cd auth-service && python -m venv .venv && .venv/Scripts/pip install -r requirements-dev.txt && .venv/Scripts/python -m pytest
cd task-service && ./mvnw test          # needs JAVA_HOME pointing at a JDK 21
cd frontend && npm install && npm run dev   # http://localhost:5173, proxies /api to :8001 / :8002
```

## Tests

- auth-service: pytest (register, duplicate email, validation, login + JWT claims, wrong password, `/me`, health).
- task-service: `@WebMvcTest` controller test (auth required, validation → ProblemDetail, status filter,
  404 mapping, ownerId ignored in body), Mockito service test (owner scoping, defaults, status change),
  and a **JWT contract test** that verifies tokens minted by the Python service.
- `scripts/smoke-test.sh`: full API flow through the public origin, locally or against AWS.

## AWS deployment (Task 2, in progress; full plan in [docs/AWS_DEPLOY_PLAN.md](docs/AWS_DEPLOY_PLAN.md))

| Piece | AWS |
|---|---|
| Frontend | S3 bucket (private) + CloudFront (Origin Access Control) |
| Backends | EC2 instance running both containers with Docker Compose |
| Databases | RDS PostgreSQL, one instance with `authdb` and `taskdb` |
| Routing | CloudFront behaviours: `/api/auth/*` and `/api/tasks*` → EC2 origin, default → S3 |
| CI/CD | GitHub Actions: build images → GHCR → SSH to EC2 `docker compose pull && up -d`; `npm run build` → `aws s3 sync` → CloudFront invalidation |

## How AI was used

See [AI_USAGE.md](AI_USAGE.md).
