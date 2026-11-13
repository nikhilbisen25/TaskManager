# Task Manager: complete implementation guide and study plan

This is the one document to learn this project from. It explains **what** was built, **how every piece
works (with the file that does it)**, **why** each decision was made, what went wrong while building it,
and how to study it before the interview.

- Live: https://d1mc2pgndcz3na.cloudfront.net · Repo: https://github.com/nikhilbisen25/TaskManager
- Companion docs: [CLAUDE.md](../CLAUDE.md) (short AI context), [AWS_DEPLOY_PLAN.md](AWS_DEPLOY_PLAN.md),
  [LIVE_CHANGE_PLAYBOOK.md](LIVE_CHANGE_PLAYBOOK.md), [AI_USAGE.md](../AI_USAGE.md)

---

## Contents

1. [The 60-second explanation](#1-the-60-second-explanation)
2. [Architecture](#2-architecture)
3. [Request flows, step by step](#3-request-flows-step-by-step)
4. [Repository map](#4-repository-map)
5. [auth-service (Python / FastAPI)](#5-auth-service-python--fastapi)
6. [task-service (Java / Spring Boot)](#6-task-service-java--spring-boot)
7. [frontend (React / Vite / Tailwind)](#7-frontend-react--vite--tailwind)
8. [Data model](#8-data-model)
9. [Security model](#9-security-model)
10. [Local environment (docker compose)](#10-local-environment-docker-compose)
11. [AWS infrastructure](#11-aws-infrastructure)
12. [CI/CD pipeline](#12-cicd-pipeline)
13. [Testing strategy](#13-testing-strategy)
14. [Problems hit while building (debug stories)](#14-problems-hit-while-building-debug-stories)
15. [Known limitations and how to fix them](#15-known-limitations-and-how-to-fix-them)
16. [Interview questions with answers](#16-interview-questions-with-answers)
17. [Study plan](#17-study-plan)
18. [Glossary](#18-glossary)

---

## 1. The 60-second explanation

> "It's a task manager split into two independently deployable services and a React SPA.
> The **auth-service** is Python/FastAPI: it registers users, hashes passwords with bcrypt, and issues
> a signed JWT. The **task-service** is Java/Spring Boot: it does task CRUD and **verifies the JWT
> locally** with the shared secret, so it never calls the auth-service at runtime. Each service owns its
> own **Postgres database** and its own migrations. The **frontend** calls a relative `/api` path, so in
> every environment one origin serves both the UI and the API: nginx locally, **CloudFront** in AWS,
> which sends `/api/auth/*` and `/api/tasks*` to EC2 and everything else to S3. That avoids CORS and
> mixed-content problems. **GitHub Actions** tests, builds only the changed images, pushes them to ECR
> tagged with the git SHA, deploys to EC2 through SSM (no SSH), uploads the frontend to S3, and runs a
> smoke test against the live URL. A frontend change goes live in about 80 seconds."

Memorise the shape, not the words: **two services, one JWT contract, one origin, one pipeline.**

---

## 2. Architecture

```
                         ┌──────────────── one public origin ────────────────┐
                         │ local: nginx in the frontend container (:8080)    │
 Browser ── HTTP(S) ───► │ AWS:   CloudFront https://d1mc2pgndcz3na.cloudfront.net
                         └────┬───────────────────┬───────────────────┬──────┘
                              │ /*                │ /api/auth/*       │ /api/tasks*
                              ▼                   ▼                   ▼
                     React SPA (static)     auth-service :8001   task-service :8002
                     local: nginx           FastAPI, Python 3.12 Spring Boot 3.5, Java 21
                     AWS:   S3 (private)    issues HS256 JWT     verifies JWT locally
                                                  │                   │
                                                  ▼                   ▼
                                            Postgres authdb     Postgres taskdb
                                            local: container    local: container
                                            AWS: one RDS instance, two databases

 JWT contract: HS256 · secret = JWT_SECRET (same in both services, ≥ 32 chars)
               claims: sub = user id (UUID), email, iat, exp (60 min)
```

| Component | Tech | Port | Owns |
|---|---|---|---|
| auth-service | Python 3.12, FastAPI, SQLAlchemy 2, Alembic, Pydantic v2, passlib/bcrypt, PyJWT | 8001 | `authdb.users` |
| task-service | Java 21, Spring Boot 3.5.16, Spring Data JPA, Flyway, Spring Security OAuth2 resource server | 8002 | `taskdb.tasks` |
| frontend | React 19, TypeScript, Vite 8, Tailwind 4, Axios, React Router 7 | 80 (nginx) / 5173 (dev) | nothing |

**Three ideas hold it together:**

1. **The JWT is the only contract between services.** Auth signs, tasks verifies. Either service can be
   rewritten, redeployed or scaled alone.
2. **Database per service.** No service reads another's tables; `tasks.owner_id` is just the JWT `sub`,
   with no foreign key across databases.
3. **Same origin everywhere.** The browser only ever calls `/api/...` on the page's own origin.

---

## 3. Request flows, step by step

### 3.1 Register

1. User fills **RegisterPage** → `register()` in `frontend/src/api/auth.ts` → `POST /api/auth/register`.
2. nginx / CloudFront matches `/api/auth/*` → auth-service.
3. FastAPI validates the body against `RegisterRequest` (`app/schemas.py`): valid email (lower-cased),
   password 8-72 chars. Invalid → **422**.
4. `register()` in `app/routers/auth.py` checks the email isn't taken (→ **409**), hashes the password
   with bcrypt (`app/security.py`), inserts a `User`, returns **201** with `UserResponse` (no hash).
5. The UI redirects to `/login` with a "registered" banner.

### 3.2 Login

1. **LoginPage** → `AuthContext.login()` → `POST /api/auth/login`.
2. `login()` looks up the user and `verify_password()`. Unknown email **and** wrong password both return
   the same **401** ("Invalid email or password") so attackers can't discover which emails exist.
3. `create_access_token()` builds `{sub, email, iat, exp}` and signs it HS256 with `JWT_SECRET`.
4. Response: `{access_token, token_type: "bearer", expires_in: 3600}`.
5. The frontend stores the token in `localStorage` (`tokenStore` in `api/client.ts`), then calls
   `GET /api/auth/me` to load the user, and navigates to the dashboard.

### 3.3 Create a task (the most important flow to explain)

1. **TaskForm** submit → `createTask()` → `POST /api/tasks` with `{title, description, status}`.
2. The Axios **request interceptor** (`api/client.ts`) adds `Authorization: Bearer <token>`.
3. CloudFront matches `/api/tasks*` → EC2:8002 (caching disabled; all headers incl. Authorization forwarded).
4. Spring Security's `BearerTokenAuthenticationFilter` extracts the token; the `JwtDecoder` bean
   (`config/SecurityConfig.java`) checks the **HS256 signature** and **exp**. Bad/expired → **401**.
   No network call to auth-service happens.
5. `TaskController.create()` gets the `Jwt` via `@AuthenticationPrincipal`, takes
   `ownerId = UUID.fromString(jwt.getSubject())`. Any `ownerId` in the body is ignored (it isn't even a
   field of `CreateTaskRequest`).
6. `@Valid` runs Bean Validation (`@NotBlank title`, size limits). Failure → `GlobalExceptionHandler`
   → **400 ProblemDetail** with `errors: {title: "must not be blank"}`.
7. `TaskService.create()` (transactional) builds the entity, defaults status to TODO, saves.
   `@PrePersist` sets `createdAt/updatedAt`.
8. Controller returns **201** + `Location: /api/tasks/{id}` + `TaskResponse` (a record, never the entity).
9. The dashboard reloads the current page of tasks.

### 3.4 Someone else's task

`GET /api/tasks/42` with a valid token for user B, where task 42 belongs to user A:
`TaskService.findOwned()` calls `repository.findByIdAndOwnerId(42, B)` → empty →
`TaskNotFoundException` → **404**, not 403. A 403 would confirm that task 42 exists.

### 3.5 Token expires

After 60 minutes task-service returns 401. The Axios **response interceptor** sees a 401 on a non-auth
call, clears the token and redirects to `/login`.

---

## 4. Repository map

```
zifo-task-manager/
├── auth-service/                 Python FastAPI service
│   ├── app/
│   │   ├── main.py               FastAPI app; docs at /api/auth/docs
│   │   ├── config.py             Settings from env (pydantic-settings), cached
│   │   ├── base.py               SQLAlchemy DeclarativeBase (no env needed → Alembic can import)
│   │   ├── db.py                 engine, SessionLocal, get_db() dependency
│   │   ├── models.py             User table
│   │   ├── schemas.py            Pydantic request/response models
│   │   ├── security.py           bcrypt hashing, JWT create/decode
│   │   ├── deps.py               get_current_user() (Bearer → User)
│   │   └── routers/auth.py       register, login, me, health
│   ├── alembic/ + alembic.ini    migrations (0001_create_users)
│   ├── tests/                    pytest: conftest (SQLite in memory), test_auth (7 tests)
│   ├── requirements*.txt         pinned deps (bcrypt pinned to 4.0.1, see §14)
│   └── Dockerfile                multi-stage, non-root, runs migrations then uvicorn
├── task-service/                 Java Spring Boot service
│   ├── src/main/java/com/zifo/taskservice/
│   │   ├── TaskServiceApplication.java
│   │   ├── config/SecurityConfig.java      stateless resource server + HS256 JwtDecoder
│   │   ├── task/Task.java                  JPA entity
│   │   ├── task/TaskStatus.java            TODO / IN_PROGRESS / DONE
│   │   ├── task/TaskRepository.java        JPA + Specifications
│   │   ├── task/TaskSpecifications.java    reusable filters
│   │   ├── task/TaskService.java           business logic, owner-scoped, transactional
│   │   ├── task/TaskController.java        REST endpoints (thin)
│   │   ├── task/TaskNotFoundException.java
│   │   ├── task/dto/TaskDtos.java          request/response records, PageResponse
│   │   └── web/GlobalExceptionHandler.java exceptions → RFC 9457 ProblemDetail
│   ├── src/main/resources/application.yml  config from env
│   ├── src/main/resources/db/migration/V1__create_tasks.sql   Flyway
│   ├── src/test/...                        TaskControllerTest, TaskServiceTest, JwtContractTest
│   ├── mvnw, .mvn/                         Maven wrapper (no system Maven needed)
│   └── Dockerfile                          JDK build stage → JRE alpine runtime, low-memory JVM flags
├── frontend/
│   ├── src/main.tsx, App.tsx               entry + routes
│   ├── src/api/client.ts                   Axios instance, interceptors, errorMessage()
│   ├── src/api/auth.ts, api/tasks.ts       typed API calls
│   ├── src/auth/AuthContext.tsx            token + current user state
│   ├── src/components/                     ProtectedRoute, TaskForm, ui.tsx (Button, Field, badges)
│   ├── src/pages/                          LoginPage, RegisterPage, DashboardPage
│   ├── src/types.ts                        mirrors backend DTOs
│   ├── vite.config.ts                      dev proxy /api/auth → :8001, /api/tasks → :8002
│   ├── nginx.conf                          prod-like routing for docker compose
│   └── Dockerfile                          node build → nginx
├── deploy/
│   ├── docker-compose.prod.yml             EC2 compose (backends only, RDS, ECR images)
│   ├── ec2/user-data.sh                    first boot: Docker, compose plugin, swap
│   ├── ec2/make-env.sh                     writes /opt/taskmanager/.env, generates secrets on EC2
│   ├── ec2/deploy.sh                       deploy / rollback with health-gated compose up
│   ├── rds/init.sql, init-db.sh            create authdb/taskdb + users on RDS
│   ├── cloudfront/spa-rewrite.js           CloudFront Function: app routes → /index.html
│   └── aws/setup.sh, teardown.sh, ssm-run.sh   infrastructure as re-runnable CLI steps
├── .github/workflows/ci.yml, deploy.yml    CI and CD
├── scripts/smoke-test.sh                   end-to-end API test against any base URL
├── docker-compose.yml, .env.example        local stack
└── docs/                                   this guide, AWS plan, playbook
```

---

## 5. auth-service (Python / FastAPI)

### 5.1 How a FastAPI request is handled

FastAPI reads the type hints on your function. `body: RegisterRequest` → parse + validate JSON with
Pydantic. `db: Session = Depends(get_db)` → call `get_db()`, inject the session, close it after the
response (it's a generator with `try/finally`). `current_user: User = Depends(get_current_user)` →
run the auth dependency first; if it raises `HTTPException(401)` the endpoint never runs.
**Dependency injection by function parameters** is the FastAPI equivalent of Spring's `@Autowired`
plus filters.

### 5.2 File by file

- **config.py**: `Settings(BaseSettings)` reads env vars (`DATABASE_URL`, `JWT_SECRET` with
  `min_length=32`, `JWT_EXPIRE_MINUTES`). `@lru_cache get_settings()` = a singleton. The app fails at
  startup if `JWT_SECRET` is missing or short, which is better than failing on the first login.
- **base.py / db.py**: `Base` is separate so Alembic can import the models without building an engine
  (which would need env vars). `create_engine(..., pool_pre_ping=True)` re-checks pooled connections
  (survives RDS restarts). `get_db()` yields a session per request.
- **models.py**: `User(id UUID PK default uuid4, email unique+indexed, full_name, password_hash, created_at server default now())`.
  SQLAlchemy 2 typed style: `Mapped[str] = mapped_column(...)`.
- **schemas.py**: Pydantic v2 models. `EmailStr` validates email format; a `field_validator`
  lower-cases it so `Alice@x.com` and `alice@x.com` are the same user. Password `max_length=72` because
  **bcrypt only uses the first 72 bytes**. `UserResponse` uses `from_attributes=True` to read straight
  from the ORM object and never includes the hash.
- **security.py**: `CryptContext(schemes=["bcrypt"])` (salted, slow by design, cost factor 12).
  `create_access_token()` returns `(token, expires_in)`. `decode_access_token()` requires `sub` and
  `exp` and pins `algorithms=["HS256"]` (prevents the classic "alg: none" / algorithm-confusion attack).
- **deps.py**: `HTTPBearer(auto_error=False)` so we return our own 401 with `WWW-Authenticate: Bearer`.
  Decodes the token, loads the user by `sub`; if the user was deleted the token stops working.
- **routers/auth.py**: the four endpoints. `/health` runs `SELECT 1`, so it reports DB problems too
  (Docker healthchecks use it).
- **main.py**: docs at `/api/auth/docs` so Swagger works behind nginx/CloudFront path routing.

### 5.3 Migrations (Alembic)

`alembic/versions/0001_create_users.py` creates `users` + unique index on email. `alembic/env.py` reads
`DATABASE_URL` from the environment. The Docker `CMD` is `alembic upgrade head && uvicorn ...`, so
**every container start applies pending migrations**. Alembic tracks applied versions in the
`alembic_version` table.

### 5.4 Tests

`tests/conftest.py` overrides the `get_db` dependency with an **in-memory SQLite** session
(`StaticPool` keeps one connection so the in-memory DB survives across requests). `test_auth.py`
covers: register (normalised email, no hash in response), duplicate → 409, validation → 422, login →
token whose claims are decoded and checked, wrong password/unknown email → 401, `/me` with
none/bad/good token, health.

---

## 6. task-service (Java / Spring Boot)

### 6.1 Layering (say this in the interview)

```
HTTP → [Security filter: verify JWT] → TaskController (thin: HTTP ↔ DTO, ownerId from token)
     → TaskService (@Transactional business rules, owner scoping, defaults)
     → TaskRepository (Spring Data JPA + Specifications) → Postgres
Errors anywhere → GlobalExceptionHandler → ProblemDetail JSON
```

The entity never leaves the service layer; the API speaks only in DTO records. That's what makes a
change like "add priority" safe: entity, DTO and migration change together, and the contract is explicit.

### 6.2 Security: `config/SecurityConfig.java`

```java
http.csrf(disable)                       // stateless API with bearer tokens, no cookies → CSRF not applicable
    .sessionManagement(STATELESS)        // no HttpSession
    .authorizeHttpRequests(GET /actuator/health → permitAll, /error → permitAll, anything else → authenticated)
    .oauth2ResourceServer(jwt())         // Spring's standard bearer-token filter
```

`jwtDecoder()` builds `NimbusJwtDecoder.withSecretKey(HmacSHA256 key).macAlgorithm(HS256)`. The default
validators check `exp`/`nbf` with 60 s clock skew. A secret shorter than 32 chars fails startup.
**Upgrade path to RS256:** replace this bean with `NimbusJwtDecoder.withJwkSetUri(".../.well-known/jwks.json")`;
nothing else in task-service changes. That's the reason for using the resource-server support
instead of a hand-written filter.

Missing/invalid token → Spring's `BearerTokenAuthenticationEntryPoint` → 401 with a
`WWW-Authenticate: Bearer error="invalid_token"` header.

### 6.3 Domain and persistence

- **Task.java**: `id` (IDENTITY → BIGSERIAL), `ownerId` (UUID, `updatable=false`), `title`,
  `description`, `status` (`@Enumerated(STRING)`, stored as text, never as ordinal), `createdAt`,
  `updatedAt` set in `@PrePersist`/`@PreUpdate`. Plain getters/setters, no Lombok.
- **TaskRepository**: `JpaRepository<Task, Long>` + `JpaSpecificationExecutor<Task>` +
  `findByIdAndOwnerId()` (derived query: Spring generates the SQL from the method name).
- **TaskSpecifications**: `ownedBy(ownerId)`, `hasStatus(status)`. Each returns `null` when its
  argument is null, and Spring ignores null specs, so `ownedBy(o).and(hasStatus(null))` = "all my tasks".
  Adding a filter = adding one method.
- **Flyway** `V1__create_tasks.sql`: table + `CHECK (status IN (...))` + indexes `(owner_id, status)`
  and `(owner_id, created_at DESC)` matching the two common queries. Hibernate runs with
  `ddl-auto: validate`: it checks the entity matches the schema but never changes it. **Flyway owns
  the schema; never edit an applied migration, always add `V{n+1}`.**

### 6.4 Service: `TaskService.java`

`@Transactional` on the class (each public method = one transaction), `readOnly = true` on reads
(lets Hibernate skip dirty checking). Every method takes `ownerId` first and goes through
`findOwned()`, so **it is impossible to touch a task without the owner check**. `create()` strips the
title and defaults status to TODO. `update()`/`updateStatus()` use `saveAndFlush` so `@PreUpdate`
runs and the response carries the new `updatedAt`.

### 6.5 Controller: `TaskController.java`

| Method | Path | Notes |
|---|---|---|
| GET | `/api/tasks?status=&page=&size=&sort=` | default size 20 (max 100), sort `createdAt,desc`; returns `PageResponse` |
| GET | `/api/tasks/{id}` | 404 if not yours |
| POST | `/api/tasks` | 201 + `Location` header |
| PUT | `/api/tasks/{id}` | full update (title, description, status) |
| PATCH | `/api/tasks/{id}/status` | just the status |
| DELETE | `/api/tasks/{id}` | 204 |

`PageResponse` is our own record `{content, page, size, totalElements, totalPages}`. Serialising
Spring's `Page` directly gives an unstable JSON shape (Spring itself warns about it).

### 6.6 Errors: `web/GlobalExceptionHandler.java`

Extends `ResponseEntityExceptionHandler`, so Spring MVC's own errors (malformed JSON, wrong method,
unsupported media type) also come back as ProblemDetail. Custom handlers: `TaskNotFoundException` →
404, `MethodArgumentTypeMismatchException` (`?status=FOO`, `/api/tasks/abc`) → 400,
`PropertyReferenceException` (`?sort=bogus`) → 400, validation → 400 with an `errors` map the UI shows.

Example body:
```json
{"type":"about:blank","title":"Invalid request","status":400,"detail":"Validation failed",
 "instance":"/api/tasks","errors":{"title":"must not be blank"}}
```

### 6.7 Configuration: `application.yml`

Everything overridable by env: `PORT`, `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`, `JWT_SECRET` (no
default: must be set). Notables: `open-in-view: false` (no lazy loading in controllers),
Hikari `maximum-pool-size: 5` (small instance), `forward-headers-strategy: framework` (correct scheme
behind proxies), actuator exposes only `health,info`.

### 6.8 Tests (17 on the rehearsal branch, 12 on main)

- **TaskControllerTest** (`@WebMvcTest` + `@Import(SecurityConfig)`): loads only the web layer with the
  real security config; `TaskService` is a `@MockitoBean`. Uses `jwt().jwt(j -> j.subject(...))` from
  spring-security-test to fake an authenticated token. Covers 401 without token, 201 + Location,
  ownerId in body ignored, blank title → ProblemDetail with `errors.title`, status filter, bad
  filter → 400, unknown task → 404.
- **TaskServiceTest** (pure Mockito, no Spring): owner set from caller, default TODO, status change,
  another user's task → not found and no delete.
- **JwtContractTest**: tokens **minted by PyJWT** (the auth-service library) are fed to the real
  `jwtDecoder()`: valid accepted (sub + email read), expired rejected, wrong secret rejected. If either
  side changes the contract, the build fails. This is the cross-service test.

### 6.9 Docker image

Build stage `eclipse-temurin:21-jdk`: copy `mvnw` + `pom.xml` first, `dependency:go-offline` (cached
layer until the pom changes), then `src` and `package -DskipTests`. Runtime `eclipse-temurin:21-jre-alpine`,
non-root user, JVM flags `-XX:MaxRAMPercentage=60 -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Xss512k`
(heap = 60 % of the container limit; serial GC and C1-only JIT to save memory and start faster on a
small box). Healthcheck: `wget /actuator/health`.

---

## 7. frontend (React / Vite / Tailwind)

- **main.tsx / App.tsx**: `AuthProvider` wraps `BrowserRouter`; routes `/login`, `/register`, `/`
  (wrapped in `ProtectedRoute`), anything else → `/`.
- **api/client.ts**: `axios.create({ baseURL: '/api' })`, **relative**, which is why the same build
  works locally, in compose and on CloudFront. Request interceptor adds the Bearer header. Response
  interceptor: 401 on a non-login call → clear token → `/login`. `errorMessage()` understands both
  FastAPI (`{detail: "..."}` or a list of validation errors) and Spring ProblemDetail
  (`{detail, errors}`), so every page shows readable errors.
- **auth/AuthContext.tsx**: holds `user` and `loading`. On first load, if a token exists, calls `/me`
  (validates the token and loads the name); on failure clears it. `login()` stores the token then loads
  `/me`. `logout()` clears both. Exposed through `useAuth()`.
- **components/ProtectedRoute.tsx**: shows "Loading…" until the `/me` check finishes, then the page or
  a redirect to `/login`.
- **pages/DashboardPage.tsx**: state = page data, status filter, page number, which task is being
  edited, error. `load()` is a `useCallback` re-run by `useEffect` when filter/page change. Every
  mutation goes through `run(action)`: do it, show errors, reload the list. Footer shows
  `Build <sha>` from `VITE_APP_VERSION` (set by the deploy workflow).
- **components/TaskForm.tsx**: one form for create and edit (`initial` prop). Add new task fields here.
- **components/ui.tsx**: tiny Tailwind building blocks (`Button` variants, `Field`, `ErrorBanner`,
  `StatusBadge`, `AuthCard`). No component library, just utility classes.
- **types.ts**: TypeScript mirrors of the backend DTOs. Keep it in sync with `TaskDtos.java`.
- **Dev mode**: `npm run dev` → Vite on :5173 proxies `/api/auth` → :8001 and `/api/tasks` → :8002.

---

## 8. Data model

**authdb.users**

| column | type | notes |
|---|---|---|
| id | uuid PK | generated in Python (`uuid4`) |
| email | varchar(255) | unique index, stored lower-case |
| full_name | varchar(100) null | |
| password_hash | varchar(255) | bcrypt, includes salt and cost |
| created_at | timestamptz | default now() |

**taskdb.tasks**

| column | type | notes |
|---|---|---|
| id | bigserial PK | |
| owner_id | uuid | = JWT `sub`; no FK (other database) |
| title | varchar(200) | not null |
| description | varchar(2000) null | |
| status | varchar(20) | default 'TODO', CHECK in (TODO, IN_PROGRESS, DONE) |
| created_at, updated_at | timestamptz | |
| indexes | | (owner_id, status), (owner_id, created_at desc) |

On the rehearsal branch V2 adds `priority varchar(10) not null default 'MEDIUM'` (+ CHECK) and
`due_date date`, plus index `(owner_id, due_date)`.

---

## 9. Security model

| Concern | How it's handled |
|---|---|
| Passwords | bcrypt (salted, slow), never returned, 72-byte cap enforced |
| Login enumeration | same 401 for unknown email and wrong password |
| Token integrity | HS256 signature; algorithm pinned on both sides; `exp` required and checked |
| Authorisation | every task query is `WHERE owner_id = <sub>`; ownerId never read from the body; foreign tasks → 404 |
| Input validation | Pydantic (auth), Bean Validation + DB CHECK constraints (tasks) |
| CORS | not needed: same origin everywhere |
| Mixed content | avoided: browser only talks HTTPS to CloudFront |
| Network | EC2 security group allows 8001-8002 **only from CloudFront's managed prefix list**; RDS SG allows 5432 only from the EC2 SG; RDS not public |
| Secrets | `JWT_SECRET` + DB user passwords generated **on the EC2 instance** into a root-only `.env`; RDS master password generated and stored by RDS in Secrets Manager; nothing secret in git or GitHub |
| CI credentials | GitHub OIDC → short-lived AWS credentials; role trusts only `nikhilbisen25/TaskManager` on `main`; permissions scoped to these resources |
| Server access | no SSH port; commands via SSM (audited in AWS) |
| Containers | non-root users in all images |

**Weak spots to admit honestly (and the fix):** token in `localStorage` is readable by injected
scripts (XSS) → httpOnly secure cookie + CSRF token, or a short-lived token + refresh token; no logout
revocation (stateless JWT) → short expiry + refresh tokens + denylist; shared HS256 secret → RS256 +
JWKS; CloudFront → EC2 hop is plain HTTP inside AWS → ALB with ACM cert or origin custom domain;
no rate limiting on login → AWS WAF rate rule or a limiter in FastAPI.

---

## 10. Local environment (docker compose)

`docker-compose.yml` runs 5 containers: `auth-db`, `task-db` (postgres:16-alpine with `pg_isready`
healthchecks and named volumes), `auth-service`, `task-service`, `frontend` (nginx). `depends_on:
condition: service_healthy` orders startup: DBs healthy → services (run migrations, then healthy) →
nginx. Memory limits (256 MB / 512 MB for the JVM / 64 MB nginx) keep the stack around 355 MB.
`.env` (copied from `.env.example`) supplies secrets; defaults let it start without one.

`frontend/nginx.conf` mirrors CloudFront: `/api/auth/` → `auth-service:8001`, `/api/tasks` →
`task-service:8002`, `/assets/` cached for a year (hashed file names), everything else
`try_files ... /index.html` (SPA fallback) with `no-cache`.

Commands: `docker compose up --build` · `./scripts/smoke-test.sh` · `docker compose down` (`-v`
also wipes the DB volumes).

---

## 11. AWS infrastructure

All created by `deploy/aws/setup.sh <step>` (region ap-south-1). Each step looks resources up by name
first, so re-running is safe.

| Step | Resource | Key settings and why |
|---|---|---|
| network | SG `taskmanager-app-sg` | inbound 8001-8002 from the CloudFront origin-facing prefix list, as **one rule** (a prefix-list rule counts ~55 entries against the 60-rule SG quota) |
| | SG `taskmanager-db-sg` | inbound 5432 from the app SG only |
| rds | `taskmanager-db` | Postgres 16.15, db.t4g.micro, 20 GB gp3, private, `--manage-master-user-password` (Secrets Manager), 1-day backups |
| ecr | `taskmanager/auth-service`, `taskmanager/task-service` | scan on push, keep last 15 images |
| buckets | `taskmanager-web-<acct>` | private; only CloudFront (OAC) can read |
| | `taskmanager-deploy-<acct>` | carries the compose file and scripts to EC2 |
| iam-ec2 | role `taskmanager-ec2-role` | SSM core, ECR read-only, read deploy bucket, read the RDS master secret |
| ec2 | `taskmanager-ec2` | t3.micro, Amazon Linux 2023, IMDSv2 required, 16 GB gp3, user-data, **Elastic IP** (stable CloudFront origin) |
| cloudfront | distribution `E21JYKNTBEZS6D` | origins: S3 (OAC), EC2:8001, EC2:8002; behaviours: default → S3 with `CachingOptimized` + SPA function; `/api/auth/*` and `/api/tasks*` → EC2 with `CachingDisabled` + `AllViewerExceptHostHeader` (forwards Authorization and query strings); HTTP → HTTPS redirect |
| github | OIDC provider + role `taskmanager-github-deploy` | trusts this repo's `main` (both GitHub subject formats, see §14); can push to these ECR repos, write these buckets, invalidate this distribution, run SSM on this instance only |
| bootstrap | (on EC2 via SSM) | sync deploy files → `make-env.sh` (secrets generated on the box) → `init-db.sh` (creates `authdb`/`taskdb` and users, each user can connect only to its own DB) |

**On the EC2 instance** (`/opt/taskmanager`): `docker-compose.prod.yml` (backends only; RDS over
`sslmode=require`; images `ECR/taskmanager/<svc>:<git sha>`), `.env` (root-only), `tags.env` (which
SHA runs), `ec2/deploy.sh`.

**`deploy.sh`**: `deploy.sh auth=<sha> task=<sha>` saves the current tags as `tags.env.prev`, writes
the new ones, logs in to ECR, `pull`, then `up -d --wait` (blocks until healthchecks pass; on failure
prints container logs and exits non-zero so the pipeline goes red). `deploy.sh rollback` restores the
previous tags.

**SPA routing**: S3 has no `/login` object. The CloudFront Function (`spa-rewrite.js`, viewer-request,
default behaviour only) rewrites any path whose last segment has no `.` to `/index.html`; React
Router then renders the right page. API paths never hit it because their behaviours match first.

**Cost**: about $1/day while running (EC2 ~$0.27, RDS ~$0.50, public IP ~$0.12, rest pennies).
`deploy/aws/teardown.sh --yes-delete-everything` removes everything.

---

## 12. CI/CD pipeline

**`ci.yml`** runs on PRs and non-main pushes, and is called by `deploy.yml`: three parallel jobs
(pytest; `mvnw test`; `npm ci && npm run build`).

**`deploy.yml`** on push to `main` (or the "Run workflow" button, which deploys everything):

```
changes (paths-filter: auth? task? frontend? infra?)
   ├── test (calls ci.yml) ───────────────┐
   ├── build-auth  (if auth changed) ─────┤──► deploy-backend (if tests pass, no build failed, backend/infra changed)
   ├── build-task  (if task changed) ─────┘       s3 sync deploy/ → SSM: sync to /opt/taskmanager, deploy.sh auth=<sha> task=<sha>
   └── deploy-frontend (after test, if anything deployable changed, so the footer SHA is always current)
          npm build (VITE_APP_VERSION=sha) → s3 sync assets (1-year cache) → index.html (no-cache) → invalidate /index.html
                                   └──────────────► smoke-test (scripts/smoke-test.sh https://$CF_DOMAIN)
```

Details worth knowing:
- **Auth to AWS**: `permissions: id-token: write` + `aws-actions/configure-aws-credentials` with
  `role-to-assume`: GitHub's OIDC token is exchanged for 1-hour AWS credentials. No stored keys.
- **Images built in parallel with tests** to save time; deploy waits for both.
- **Build cache**: `docker/build-push-action` with `cache-from/to: type=gha` per service; the Maven
  dependencies sit in their own layer so they're reused until `pom.xml` changes.
- **Tags = full git SHA**: you can always tell which commit runs (also shown in the footer).
- **`concurrency: deploy-production`, `cancel-in-progress: false`**: deploys never overlap or get killed midway.
- **Config** comes from 8 repository *variables* (not secrets): region, role ARN, registry, instance id,
  buckets, distribution id, domain.

**Measured:** frontend-only push → live in **82 s**; full rebuild with an empty cache **3 min 25 s**
(task-service image build 126 s is the long pole); backend change with warm cache ≈ 2.5-3 min (estimate).

---

## 13. Testing strategy

| Level | Where | What it proves |
|---|---|---|
| Unit | `TaskServiceTest` | business rules with no Spring or DB (fast) |
| Web slice | `TaskControllerTest` | URL mapping, JSON, validation, security config, error format |
| API (in-process) | `auth-service/tests` | real FastAPI app + SQLAlchemy on SQLite |
| Contract | `JwtContractTest` | Python-issued tokens verify in Java |
| End to end | `scripts/smoke-test.sh` | the deployed system through the public origin (runs at the end of every deploy) |
| Manual | browser | UI flows |

Gap to mention: no integration test against a real Postgres in CI (Testcontainers would add that:
runs Flyway + repository queries against a throwaway Postgres in Docker).

---

## 14. Problems hit while building (debug stories)

Good interview material: each one shows reading the actual error instead of guessing.

1. **Spring Initializr only offers Boot 4.x now.** The brief said 3.x → pinned the parent to 3.5.16 by hand.
2. **passlib + bcrypt ≥ 4.1 are incompatible** (passlib reads a removed attribute and its self-test
   breaks) → pinned `bcrypt==4.0.1`, documented in `requirements.txt`.
3. **Alembic needed `JWT_SECRET`** because importing models imported `db.py`, which built the engine
   from settings → moved `Base` to `app/base.py`.
4. **Ambiguous Mockito `delete(any())`**: the repository has `delete(T)` and `delete(Specification)` →
   `any(Task.class)`.
5. **BuildKit cache mounts aren't kept by GitHub's layer cache** → every CI build would re-download
   Maven deps → moved deps into a normal cached layer (after a source-only change `package` takes ~24 s).
6. **RDS master user isn't a superuser**: `CREATE DATABASE ... OWNER auth` needs role membership →
   `init.sql` grants the roles to itself first; tested against Postgres 16 as a non-superuser.
7. **Git Bash rewrites `/aws/...` arguments into `C:/Program Files/Git/aws/...`** → scripts set `MSYS_NO_PATHCONV=1`.
8. **GitHub Actions couldn't assume the AWS role.** CloudTrail `AssumeRoleWithWebIdentity` events showed
   `AccessDenied` with subject `repo:nikhilbisen25@72607459/TaskManager@1455177784:ref:refs/heads/main`.
   GitHub now sends this immutable-ID format; the role trusted only `repo:nikhilbisen25/TaskManager:...`.
   Fix: `setup.sh github` reads both IDs from the GitHub API and trusts both formats. **Lesson: for auth
   failures, read the server-side audit log first.**
9. **After the rehearsal, local `main` wouldn't have started**: Flyway refuses a database that has a
   migration (V2) the code doesn't know → reset the local task DB volume. The same reason the
   rehearsal branch must never reach RDS.

---

## 15. Known limitations and how to fix them

| Limitation | Production fix |
|---|---|
| Single EC2 = single point of failure; ~20-30 s of 5xx while a container is replaced on deploy | ECS Fargate or an Auto Scaling group behind an ALB with rolling / blue-green deploys and 2+ tasks |
| Single-AZ RDS | Multi-AZ, automated backups with longer retention, read replica if needed |
| No centralised logs/metrics | CloudWatch agent / awslogs driver, CloudWatch alarms, OpenTelemetry tracing across both services |
| JWT in localStorage, no refresh/revocation | httpOnly cookie or short access token + refresh token, denylist on logout |
| Shared HS256 secret | RS256 + JWKS endpoint on auth-service |
| No rate limiting | AWS WAF on CloudFront |
| Plain HTTP CloudFront → EC2 | ALB + ACM certificate (HTTPS origin) |
| No DB integration tests in CI | Testcontainers |
| Infra as CLI scripts | Terraform / CDK for drift detection and reviewable plans |
| Secrets in a file on the box | SSM Parameter Store / Secrets Manager read at startup |

---

## 16. Interview questions with answers

**Why microservices for something this small?** The brief asked for it; the value shown here is the
*boundaries*: independent deploys, independent databases, a single explicit contract (the JWT),
polyglot stacks. For a real product this size I'd start as a modular monolith and split when team or
scaling needs justify it.

**Why does task-service not call auth-service?** Local JWT verification removes a runtime dependency
and a network hop per request; if auth-service is down, existing sessions still work. Cost: you can't
revoke a token before it expires (mitigate with short expiry + refresh tokens).

**HS256 vs RS256?** HS256 = one shared secret that can both sign and verify, so every verifier could
also forge tokens. RS256 = auth-service keeps the private key and publishes the public key (JWKS);
verifiers can't forge. Switching is one bean in `SecurityConfig`.

**How do you stop users seeing each other's tasks?** `ownerId` comes only from the verified token;
every repository call is owner-scoped through `findOwned()` / `ownedBy()`; foreign IDs return 404.
Covered by tests.

**Why 404 and not 403?** 403 would confirm the resource exists (an information leak).

**Why ProblemDetail?** RFC 9457 standard error shape; one format for all errors; machine-readable
`errors` map for field validation that the UI displays.

**Why Flyway/Alembic instead of `ddl-auto=update`?** Versioned, reviewable, repeatable schema changes
that run the same in every environment; Hibernate only validates. For zero-downtime changes use
expand/contract: add nullable/defaulted columns first, deploy code, backfill, then tighten.

**How does a deploy work, and how do you roll back?** (§12) Push → tests ‖ changed images built,
SHA-tagged → ECR → SSM runs `deploy.sh` → health-gated → frontend to S3 + invalidation → smoke test.
Rollback: `deploy.sh rollback` (previous SHAs), or redeploy any older SHA.

**Why CloudFront in front of the API too?** One HTTPS origin: no CORS, no mixed content, TLS for
free with the default certificate, and the backends get hidden behind a CloudFront-only security group.

**Why EC2 + compose instead of ECS?** Fastest path in the timebox with the same model as local
development and easy live debugging; ECS Fargate + ALB is the production step (no servers, rolling deploys).

**How would you scale it?** Both services are stateless → run more replicas behind an ALB (or
ECS service with autoscaling); RDS vertical scaling then read replicas; CloudFront already caches the static app.

**What would you monitor?** 5xx rate and latency per behaviour (CloudFront/ALB metrics), container
health and restarts, JVM heap, RDS CPU/connections/storage, failed logins; alerts to email/Slack.

**How did you use AI?** (`AI_USAGE.md`) Context → goal → constraints → acceptance → plan first; I
review the plan and the diff, run tests, then push. `CLAUDE.md` gives the assistant standing project
context. The AI caught real issues (bcrypt pin, Initializr version, cache mounts, RDS grants) and I
used it to debug the OIDC failure from CloudTrail evidence.

---

## 17. Study plan

### Tonight (≈ 2 h)

| Time | Do | Goal |
|---|---|---|
| 15 min | Read §1-§3 of this guide; say the 60-second explanation out loud twice | own the big picture |
| 25 min | Open `TaskController` → `TaskService` → `TaskRepository` → `TaskSpecifications` → `Task` → `V1__create_tasks.sql` | trace a request through the layers |
| 15 min | `SecurityConfig.java` + `JwtContractTest.java`; then `auth-service/app/security.py` | explain the JWT contract from both sides |
| 15 min | `frontend/src/api/client.ts`, `AuthContext.tsx`, `DashboardPage.tsx` | explain token handling and data loading |
| 20 min | `.github/workflows/deploy.yml` + `deploy/ec2/deploy.sh` | explain the pipeline and rollback |
| 15 min | `git diff main..rehearsal/priority-due-date` | know exactly what the live change touches |
| 15 min | §16 questions: answer each aloud without looking | fluency |

### Hands-on exercises (pick 3-4; each is a few minutes)

1. **Decode your own token** (never paste real tokens into websites): log in on the live site, copy
   the `tm_token` value from DevTools → Application → Local Storage, then
   `python -c "import jwt,sys; print(jwt.decode(sys.argv[1], options={'verify_signature': False}))" <token>`
   (run it with the auth-service venv). See `sub`, `email`, `exp`.
2. **Prove ownership**: with the smoke script's style of curl calls, create a task as user A, then
   `GET /api/tasks/<id>` with user B's token → 404.
3. **Prove the 401 path**: `curl -i https://d1mc2pgndcz3na.cloudfront.net/api/tasks` and read the
   `WWW-Authenticate` header.
4. **See ProblemDetail**: `POST /api/tasks` with `{"title":"  "}` and a valid token → read the `errors` map.
5. **Read the pipeline**: open the last green Deploy run on GitHub; note which jobs were skipped and why
   (paths filter).
6. **Look at the server**: AWS console → EC2 → instance → Connect → Session Manager →
   `sudo cat /opt/taskmanager/tags.env` and `sudo docker ps`. Compare the SHA with the footer.
7. **Swagger**: https://d1mc2pgndcz3na.cloudfront.net/api/auth/docs, try register/login.

### Tomorrow morning (≈ 45 min)

- Run through [LIVE_CHANGE_PLAYBOOK.md](LIVE_CHANGE_PLAYBOOK.md) once without touching code: say each step.
- Re-read §14 (debug stories) and §15 (limitations): interviewers like "what would you improve?"
- Check the live URL, last pipeline green, demo login works.

### Self-check: can you answer these without looking?

1. Which file decides that a missing token returns 401 in task-service?
2. Where does the owner of a new task come from, and why not the request body?
3. What happens when you add a NOT NULL column without a DEFAULT in a Flyway migration on a table with rows?
4. Why does the frontend use `/api` instead of `http://localhost:8001`?
5. What does the CloudFront Function do, and why doesn't it break `/api/tasks`?
6. What are the two ways the pipeline avoids storing AWS keys and SSH keys?
7. How do you roll back a bad backend deploy?
8. Why is `bcrypt` pinned to 4.0.1, and why is the password capped at 72 characters?
9. What does `JwtContractTest` protect against?
10. Which job in the pipeline is the slowest, and what makes it fast on a warm cache?

(Answers: §6.2 · §3.3 · it fails, existing rows would violate the constraint · §2/§7 · §11 ·
§12 OIDC + SSM · §11 `deploy.sh rollback` · §5.2/§14 · §6.8 · §12 task-service image; cached Maven layer.)

---

## 18. Glossary

| Term | Meaning here |
|---|---|
| JWT | JSON Web Token: base64 header.payload.signature; we sign with HS256 |
| `sub` claim | "subject": the user id the token is about |
| Resource server | OAuth2 term for an API that only *verifies* tokens (task-service) |
| ProblemDetail | RFC 9457 JSON error format (`type, title, status, detail, instance` + extras) |
| Specification | Spring Data JPA object representing one WHERE condition, composable with `and()` |
| Flyway / Alembic | versioned DB migration tools for Java / Python |
| OAC | CloudFront Origin Access Control: lets only CloudFront read a private S3 bucket |
| CloudFront behaviour | a path pattern → origin + cache policy rule |
| Prefix list | AWS-managed list of IP ranges (here: CloudFront's origin-facing IPs) usable in security groups |
| OIDC (GitHub → AWS) | GitHub issues a signed identity token per workflow run; AWS trades it for temporary credentials |
| SSM Run Command | AWS service that runs shell commands on an instance through its agent (no SSH) |
| ECR | AWS container registry |
| Invalidation | telling CloudFront to drop a cached object so the next request fetches the new one |
| Paths filter | workflow step that detects which folders changed so only those parts are built/deployed |
