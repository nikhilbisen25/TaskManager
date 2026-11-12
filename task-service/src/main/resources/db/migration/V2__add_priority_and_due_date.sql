-- Priority (defaults to MEDIUM so existing rows and older clients keep working) and optional due date.
ALTER TABLE tasks
    ADD COLUMN priority VARCHAR(10) NOT NULL DEFAULT 'MEDIUM',
    ADD COLUMN due_date DATE,
    ADD CONSTRAINT chk_tasks_priority CHECK (priority IN ('LOW', 'MEDIUM', 'HIGH'));

-- Supports the dueBefore filter (always combined with owner_id).
CREATE INDEX idx_tasks_owner_due ON tasks (owner_id, due_date);
