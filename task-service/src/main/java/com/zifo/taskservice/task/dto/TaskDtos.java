package com.zifo.taskservice.task.dto;

import java.time.Instant;
import java.util.List;

import org.springframework.data.domain.Page;

import com.zifo.taskservice.task.Task;
import com.zifo.taskservice.task.TaskStatus;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * API request/response records. The entity is never exposed directly, and ownerId is deliberately absent
 * from every request type: it always comes from the JWT.
 */
public final class TaskDtos {

    private TaskDtos() {
    }

    /** POST /api/tasks. Status is optional and defaults to TODO. */
    public record CreateTaskRequest(
            @NotBlank @Size(max = 200) String title,
            @Size(max = 2000) String description,
            TaskStatus status) {
    }

    /** PUT /api/tasks/{id}: full replace of the editable fields. */
    public record UpdateTaskRequest(
            @NotBlank @Size(max = 200) String title,
            @Size(max = 2000) String description,
            @NotNull TaskStatus status) {
    }

    /** PATCH /api/tasks/{id}/status. */
    public record UpdateStatusRequest(@NotNull TaskStatus status) {
    }

    public record TaskResponse(
            Long id,
            String title,
            String description,
            TaskStatus status,
            Instant createdAt,
            Instant updatedAt) {

        public static TaskResponse from(Task t) {
            return new TaskResponse(t.getId(), t.getTitle(), t.getDescription(), t.getStatus(),
                    t.getCreatedAt(), t.getUpdatedAt());
        }
    }

    /** Stable JSON shape for paged results (instead of serialising Spring's Page directly). */
    public record PageResponse<T>(
            List<T> content,
            int page,
            int size,
            long totalElements,
            int totalPages) {

        public static <T> PageResponse<T> from(Page<T> p) {
            return new PageResponse<>(p.getContent(), p.getNumber(), p.getSize(), p.getTotalElements(),
                    p.getTotalPages());
        }
    }
}
