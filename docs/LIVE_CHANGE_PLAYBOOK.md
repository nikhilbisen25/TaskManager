# Live change playbook (interview, Fri 13 Nov)

Rehearsed on 2026-11-12 with "priority + due date + filters" (branch `rehearsal/priority-due-date`,
commit `3b27fa4`, **never merge it**). Live URL: https://d1mc2pgndcz3na.cloudfront.net

## Before the call (≈ 1:30 PM)

- [ ] `git checkout main && git pull` · working tree clean (`git status`)
- [ ] GitHub → Actions: last **Deploy** run green · live URL loads · footer shows the latest commit
- [ ] Sign in with the demo user from `.env.example` on the live URL; a couple of tasks exist
- [ ] Tabs open: live URL · GitHub Actions · VS Code with the repo · Claude Code in the repo
- [ ] Docker Desktop **not** needed (CI builds the images); close it to free RAM

## The loop on the call (target ≈ 15-20 min, pipeline ≈ 3 min of it)

1. **Restate the requirement** in one sentence and say what you will *not* change (auth-service, JWT contract).
2. **Prompt** (adapt to the actual requirement; this is the rehearsed one):

   > In task-service and the React frontend, add `priority` (LOW/MEDIUM/HIGH, default MEDIUM) and an
   > optional `dueDate` (LocalDate) to tasks. Follow the "adding a task field" recipe in CLAUDE.md:
   > new Flyway migration V2, entity, DTOs (keep older clients that omit priority working), response,
   > and list filters `?priority=` and `?dueBefore=` (inclusive) via TaskSpecifications. Frontend:
   > priority select + date input in TaskForm, a priority badge, overdue highlight, and two filter
   > controls. Don't touch auth-service or the JWT. Add tests. **Show me the plan first.**

3. **Review the plan out loud** against this checklist, then say "go":
   - a **new** migration file `V2__…sql` (V1 is never edited); NOT NULL column has a DEFAULT
   - `ownerId` still only from the token; new fields only in DTOs, not trusted from elsewhere
   - list filters as specs (null = no filter), maybe a `TaskFilter` record instead of growing params
   - tests: controller (filters bound, validation) + service (defaults)
4. **Review the diff** (VS Code source control view). Things worth pointing at:
   migration · `TaskSpecifications` · DTO defaults · the frontend types mirror the backend.
5. **Run tests locally** (≈ 1 min):
   ```bash
   cd task-service && JAVA_HOME="/c/Users/Dell/.jdks/ms-21.0.11" ./mvnw -B -q test
   cd ../frontend && npm run build
   ```
   Skip the local docker rebuild on the call: it took 6.5 min on this laptop. CI builds the images.
6. **Commit and push** (`git commit -am "Add task priority, due date and filters"` then `git push`).
7. **While the pipeline runs (≈ 2.5-3 min)**, narrate it on the Actions tab: tests ‖ only changed images
   built (auth-service skipped), tagged with the git SHA → ECR → SSM runs `deploy.sh` on EC2 (no SSH) →
   containers must pass health checks → Flyway V2 runs against RDS on startup → frontend to S3 +
   invalidation → smoke test against the live URL.
8. **Show it live**: hard refresh, footer shows the new commit, create a HIGH task due yesterday → red
   "Overdue", filter by priority. Share the URL.
9. **Show AI usage**: the prompt, where you corrected the plan, the tests, `AI_USAGE.md`.

## What the rehearsal produced (for reference, don't copy blindly)

15 files, +360/-35: V2 migration, `TaskPriority`, `TaskFilter`, two new specs, controller params,
DTOs, 5 new tests (17 total) · frontend types/api/TaskForm/ui/Dashboard. Verified: old clients
(smoke test) still work, defaults apply, filters combine, `dueBefore=bad` and `priority=URGENT` → 400.

## If something goes wrong

| Problem | Do this |
|---|---|
| AI output is wrong or slow | Correct it with a short follow-up; worst case `git checkout rehearsal/priority-due-date -- task-service frontend` gives the working version (then review + push as usual) |
| Test fails in CI | Read the failing test in the Actions log, fix, push again (deploy only runs after tests pass, so prod is safe) |
| Deploy step fails (unhealthy container) | The job log includes the container logs. Compose has already replaced the old container, so roll back first: AWS console → EC2 → Connect → Session Manager → `sudo bash /opt/taskmanager/ec2/deploy.sh rollback`, then fix and push |
| Flyway error on startup | Usually an edited old migration or a NOT NULL column without DEFAULT. Fix with a new migration, push |
| Old UI after deploy | Hard refresh (Ctrl+F5); check the footer commit |
| Different requirement than rehearsed | Same loop. Recipe in CLAUDE.md covers new fields/filters; for a new endpoint follow controller → service → repository + test |

## Talking points (if asked "why")

- Path filters + SHA-tagged images: only what changed is rebuilt; every deploy traceable and reversible.
- Migrations run on startup and are additive, so code and schema ship together.
- OIDC + SSM: no AWS keys in GitHub, no SSH port open; role scoped to this repo's `main`.
- The CloudTrail debugging story (GitHub's new OIDC subject format), see AI_USAGE.md.
