package com.zifo.taskservice.task;

import java.time.LocalDate;

/**
 * Optional list filters; a null field means "don't filter on this".
 * Adding a filter = add a field here, a spec in {@link TaskSpecifications}, a request param in the controller.
 */
public record TaskFilter(TaskStatus status, TaskPriority priority, LocalDate dueBefore) {

    public static TaskFilter none() {
        return new TaskFilter(null, null, null);
    }
}
