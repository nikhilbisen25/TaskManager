# Seeing what the system does: logs and data

How to watch requests while someone uses the app, and how to look at the rows in both databases,
locally and on AWS. Everything here is read-only.

| I want to see… | Fastest way |
|---|---|
| The API calls the page makes | Browser DevTools → Network |
| Backend logs live while clicking around (AWS) | Session Manager → `sudo bash /opt/taskmanager/ec2/logs.sh -f` |
| Recent backend logs from the laptop (AWS) | `./scripts/aws.sh logs` |
| Rows in both RDS databases | `./scripts/aws.sh db summary` |
| Local logs / local DB rows | `docker compose logs -f` · `docker compose exec task-db psql -U task -d taskdb` |
| Traffic, errors, cache hits at the edge | CloudFront console → Monitoring / Reports |

## What gets logged

**task-service**: one line per API request (`http` logger), plus one line per change:
```
INFO http        : POST /api/tasks -> 201 (14 ms)
INFO TaskService : Task 12 created by user 38795c64-07ab-45bb-9b04-fa3b4ff623bc (status TODO)
INFO http        : PATCH /api/tasks/12/status -> 200 (9 ms)
INFO TaskService : Task 12 status TODO -> DONE by user 38795c64-...
INFO http        : GET /api/tasks?page=0&size=10&sort=createdAt,desc -> 200 (6 ms)
INFO http        : GET /api/tasks -> 401 (1 ms)          ← no token (logged before security runs)
```
**auth-service**: uvicorn's access log plus app events (user **ids** only, never emails or passwords);
health-check lines are filtered out:
```
INFO: app.auth - User registered id=ec265128-...
INFO: 10.0.1.5:50111 - "POST /api/auth/register HTTP/1.1" 201 Created
WARNING: app.auth - Login failed (unknown email or wrong password)
INFO: app.auth - Login ok user=ec265128-...
```
The user id in both services is the same value (JWT `sub`), so you can follow one user across services.

---

## 1. In the browser (no setup)

1. Open the live URL, press **F12** → **Network** tab → filter **Fetch/XHR**.
2. Add a task. You'll see `POST tasks` (201) followed by `GET tasks?...` (200).
3. Click a request: **Headers** (note `Authorization: Bearer …`), **Payload** (what was sent),
   **Response** (what came back, e.g. the ProblemDetail on a validation error).
4. **Application** tab → Local Storage → `tm_token` is the JWT the app is using.

## 2. Locally (docker compose)

Start the stack (`docker compose up -d`), then:

```bash
docker compose logs -f auth-service task-service      # live logs, Ctrl+C to stop
docker compose logs --tail 50 task-service            # recent lines
```

Databases (each service has its own Postgres container):

```bash
docker compose exec auth-db psql -U auth -d authdb    # then: \dt   select id, email, created_at from users;
docker compose exec task-db psql -U task -d taskdb    # then: select id, owner_id, title, status from tasks;
```

One-liners:

```bash
docker compose exec auth-db psql -U auth -d authdb -c "select id, email, created_at from users order by created_at"
docker compose exec task-db psql -U task -d taskdb -c "select id, owner_id, title, status, updated_at from tasks order by updated_at desc limit 20"
docker compose exec task-db psql -U task -d taskdb -c "select version, description, installed_on from flyway_schema_history"
```

A GUI client (DBeaver, pgAdmin) can't reach the local DBs because their ports aren't published. Add
`ports: ["5433:5432"]` (task-db) / `["5434:5432"]` (auth-db) in `docker-compose.yml` if you want that.

## 3. AWS: backend logs (EC2)

### Option A: live, in the AWS console (best for a demo)

1. AWS console → **EC2** → Instances → `taskmanager-ec2` → **Connect** → **Session Manager** tab → **Connect**.
   (No SSH key, no open port: this is SSM.)
2. In the browser terminal:
   ```bash
   sudo bash /opt/taskmanager/ec2/logs.sh -f          # both services, live
   sudo bash /opt/taskmanager/ec2/logs.sh -f task     # only task-service
   sudo bash /opt/taskmanager/ec2/logs.sh auth 200    # last 200 lines of auth-service
   ```
3. Put the app and this terminal side by side, add/edit/delete a task, and watch the lines appear.

### Option B: from the laptop (Git Bash, AWS CLI configured)

```bash
./scripts/aws.sh logs                 # last 100 lines, both services
./scripts/aws.sh logs task 50         # task-service only
./scripts/aws.sh status               # deployed git SHAs, container health, memory, disk
```
These use SSM Run Command, so each call takes a few seconds and isn't live-following.

## 4. AWS: database rows (RDS)

RDS is private (not reachable from the internet), so every option goes through the EC2 instance.

### Option A: summary from the laptop

```bash
./scripts/aws.sh db summary
```
Prints every user with their TODO / IN_PROGRESS / DONE counts (the script reads `authdb.users` and
`taskdb.tasks` and matches `tasks.owner_id` to `users.id`; there's no SQL join because they are
separate databases), the latest 10 tasks, and the applied Alembic/Flyway versions.

One query at a time:

```bash
./scripts/aws.sh db task "select id, title, status, updated_at from tasks order by id desc limit 20"
./scripts/aws.sh db auth "select id, email, created_at from users order by created_at"
```

### Option B: interactive psql (Session Manager)

```bash
sudo bash /opt/taskmanager/ec2/db.sh summary
sudo bash /opt/taskmanager/ec2/db.sh task        # psql on taskdb:  \dt   \d tasks   select ...;   \q
sudo bash /opt/taskmanager/ec2/db.sh auth        # psql on authdb
```
Each connects as that service's own DB user, which also demonstrates the isolation: `auth` can't open
`taskdb` and vice versa.

### Option C: a GUI client on the laptop (DBeaver / pgAdmin) via an SSM tunnel

One-time: install the **Session Manager plugin** for the AWS CLI (Windows installer on the AWS docs page
"Install the Session Manager plugin for the AWS CLI").

1. Open the tunnel (keep this window open):
   ```bash
   aws ssm start-session --region ap-south-1 --target i-08a82987d322ab0e6 \
     --document-name AWS-StartPortForwardingSessionToRemoteHost \
     --parameters host=taskmanager-db.clqweeiqef5m.ap-south-1.rds.amazonaws.com,portNumber=5432,localPortNumber=15432
   ```
2. Get the DB user passwords yourself in a Session Manager terminal:
   `sudo grep DB_PASSWORD /opt/taskmanager/.env` (don't paste them into chats or commits).
3. In DBeaver: host `localhost`, port `15432`, database `taskdb`, user `task` (or `authdb` / `auth`),
   SSL mode `require`.

## 5. AWS: EC2 system, deploy history and audit

| What | Where |
|---|---|
| First-boot setup log | Session Manager: `sudo tail -100 /var/log/cloud-init-output.log` |
| Docker / SSM agent logs | `sudo journalctl -u docker --since today` · `sudo journalctl -u amazon-ssm-agent --since today` |
| Every deploy and helper command run on the box | AWS console → **Systems Manager** → **Run Command** → Command history (click one → Output) |
| Each pipeline run, step by step | GitHub → Actions → Deploy → a run → a job |
| Who did what in AWS (API calls, role sign-ins, invalidations) | AWS console → **CloudTrail** → Event history |
| Instance CPU, network | EC2 → instance → **Monitoring** tab |
| RDS CPU, connections, storage | RDS → `taskmanager-db` → **Monitoring** tab |

## 6. AWS: S3 and CloudFront

S3 only stores the built frontend; browsers never talk to S3 directly (only CloudFront can read the
bucket), so the useful request data lives in **CloudFront**:

- **CloudFront console** → distribution `E21JYKNTBEZS6D` → **Monitoring**: requests, bytes, 4xx/5xx
  error rates per minute (no setup needed).
- **CloudFront** → **Reports and analytics**: cache statistics (hit/miss), popular objects, viewers by
  country/browser.
- **CloudFront** → distribution → **Invalidations**: one entry per frontend deploy.
- What's deployed in S3: S3 console → `taskmanager-web-720428162975`, or
  `aws s3 ls s3://taskmanager-web-720428162975 --recursive`.

Per-request access logs for S3/CloudFront are **not enabled** (not needed so far). If wanted:
CloudFront → distribution → **Logging** → add a standard-logging destination (CloudWatch Logs or an S3
bucket). Costs are negligible at this traffic; logs arrive within a few minutes.

## 7. Demo script (2 minutes)

1. Session Manager: `sudo bash /opt/taskmanager/ec2/logs.sh -f`, next to the app.
2. Log in → see `Login ok user=<id>`; add a task → `POST /api/tasks -> 201` and `Task N created by user <id>`.
3. Change status → `status TODO -> DONE`. Call `/api/tasks` without a token (or show it in DevTools) → `-> 401`.
4. `Ctrl+C`, then `sudo bash /opt/taskmanager/ec2/db.sh summary`: the same user id with the new counts,
   read from two separate databases.

## 8. Production upgrade path (talking points)

- Ship container logs to **CloudWatch Logs** (`awslogs` logging driver + IAM permission), then use
  **Live Tail** and Logs Insights queries instead of logging into the box.
- Add a **request/correlation id** (from CloudFront's `X-Amz-Cf-Id` or a generated header) to every log line
  in both services, and structured JSON logs.
- Metrics and alarms: 5xx rate and latency (CloudFront/ALB), container restarts, JVM heap, RDS
  connections; **OpenTelemetry** tracing across auth → task.
