package com.zifo.taskservice.task;

import java.net.URI;
import java.util.UUID;

import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.web.PageableDefault;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.zifo.taskservice.task.dto.TaskDtos.CreateTaskRequest;
import com.zifo.taskservice.task.dto.TaskDtos.PageResponse;
import com.zifo.taskservice.task.dto.TaskDtos.TaskResponse;
import com.zifo.taskservice.task.dto.TaskDtos.UpdateStatusRequest;
import com.zifo.taskservice.task.dto.TaskDtos.UpdateTaskRequest;

import jakarta.validation.Valid;

@RestController
@RequestMapping("/api/tasks")
public class TaskController {

    private final TaskService service;

    public TaskController(TaskService service) {
        this.service = service;
    }

    /** GET /api/tasks?status=TODO&page=0&size=20&sort=createdAt,desc */
    @GetMapping
    public PageResponse<TaskResponse> list(
            @AuthenticationPrincipal Jwt jwt,
            @RequestParam(required = false) TaskStatus status,
            @PageableDefault(size = 20, sort = "createdAt", direction = Sort.Direction.DESC) Pageable pageable) {
        return PageResponse.from(service.list(ownerId(jwt), status, pageable));
    }

    @GetMapping("/{id}")
    public TaskResponse get(@AuthenticationPrincipal Jwt jwt, @PathVariable Long id) {
        return service.get(ownerId(jwt), id);
    }

    @PostMapping
    public ResponseEntity<TaskResponse> create(@AuthenticationPrincipal Jwt jwt,
            @Valid @RequestBody CreateTaskRequest req) {
        var created = service.create(ownerId(jwt), req);
        return ResponseEntity.created(URI.create("/api/tasks/" + created.id())).body(created);
    }

    @PutMapping("/{id}")
    public TaskResponse update(@AuthenticationPrincipal Jwt jwt, @PathVariable Long id,
            @Valid @RequestBody UpdateTaskRequest req) {
        return service.update(ownerId(jwt), id, req);
    }

    @PatchMapping("/{id}/status")
    public TaskResponse updateStatus(@AuthenticationPrincipal Jwt jwt, @PathVariable Long id,
            @Valid @RequestBody UpdateStatusRequest req) {
        return service.updateStatus(ownerId(jwt), id, req.status());
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@AuthenticationPrincipal Jwt jwt, @PathVariable Long id) {
        service.delete(ownerId(jwt), id);
        return ResponseEntity.noContent().build();
    }

    /** The owner is always the authenticated user (JWT "sub"), never a request field. */
    private static UUID ownerId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
