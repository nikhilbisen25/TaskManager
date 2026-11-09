package com.zifo.taskservice.task;

import java.util.UUID;

import org.springframework.data.jpa.domain.Specification;

/** Reusable query filters. A null argument means "no filter" so callers can always chain them. */
public final class TaskSpecifications {

    private TaskSpecifications() {
    }

    public static Specification<Task> ownedBy(UUID ownerId) {
        return (root, query, cb) -> cb.equal(root.get("ownerId"), ownerId);
    }

    public static Specification<Task> hasStatus(TaskStatus status) {
        return (root, query, cb) -> status == null ? null : cb.equal(root.get("status"), status);
    }
}
