-- Tasks belong to a user from auth-service. There is no FK: the users table lives in another
-- service's database (database-per-service), so owner_id is just the JWT "sub".
CREATE TABLE tasks (
    id          BIGSERIAL     PRIMARY KEY,
    owner_id    UUID          NOT NULL,
    title       VARCHAR(200)  NOT NULL,
    description VARCHAR(2000),
    status      VARCHAR(20)   NOT NULL DEFAULT 'TODO',
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT chk_tasks_status CHECK (status IN ('TODO', 'IN_PROGRESS', 'DONE'))
);

CREATE INDEX idx_tasks_owner_status ON tasks (owner_id, status);
CREATE INDEX idx_tasks_owner_created ON tasks (owner_id, created_at DESC);
