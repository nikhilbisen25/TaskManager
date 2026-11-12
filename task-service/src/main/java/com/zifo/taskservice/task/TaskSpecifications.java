package com.zifo.taskservice.task;

import java.time.LocalDate;
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

    public static Specification<Task> hasPriority(TaskPriority priority) {
        return (root, query, cb) -> priority == null ? null : cb.equal(root.get("priority"), priority);
    }

    /** Due on or before the given date (inclusive). Tasks without a due date never match. */
    public static Specification<Task> dueOnOrBefore(LocalDate date) {
        return (root, query, cb) -> date == null ? null : cb.lessThanOrEqualTo(root.get("dueDate"), date);
    }

    public static Specification<Task> matching(UUID ownerId, TaskFilter filter) {
        return ownedBy(ownerId)
                .and(hasStatus(filter.status()))
                .and(hasPriority(filter.priority()))
                .and(dueOnOrBefore(filter.dueBefore()));
    }
}
