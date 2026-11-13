package com.zifo.taskservice.task;

import static com.zifo.taskservice.task.TaskSpecifications.hasStatus;
import static com.zifo.taskservice.task.TaskSpecifications.ownedBy;

import java.util.UUID;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.zifo.taskservice.task.dto.TaskDtos.CreateTaskRequest;
import com.zifo.taskservice.task.dto.TaskDtos.TaskResponse;
import com.zifo.taskservice.task.dto.TaskDtos.UpdateTaskRequest;

/** Business logic. Every method is scoped to the owner taken from the JWT. */
@Service
@Transactional
public class TaskService {

    private static final Logger log = LoggerFactory.getLogger(TaskService.class);

    private final TaskRepository repository;

    public TaskService(TaskRepository repository) {
        this.repository = repository;
    }

    @Transactional(readOnly = true)
    public Page<TaskResponse> list(UUID ownerId, TaskStatus status, Pageable pageable) {
        return repository.findAll(ownedBy(ownerId).and(hasStatus(status)), pageable)
                .map(TaskResponse::from);
    }

    @Transactional(readOnly = true)
    public TaskResponse get(UUID ownerId, Long id) {
        return TaskResponse.from(findOwned(ownerId, id));
    }

    public TaskResponse create(UUID ownerId, CreateTaskRequest req) {
        var task = new Task();
        task.setOwnerId(ownerId);
        task.setTitle(req.title().strip());
        task.setDescription(req.description());
        task.setStatus(req.status() != null ? req.status() : TaskStatus.TODO);
        var saved = repository.save(task);
        log.info("Task {} created by user {} (status {})", saved.getId(), ownerId, saved.getStatus());
        return TaskResponse.from(saved);
    }

    public TaskResponse update(UUID ownerId, Long id, UpdateTaskRequest req) {
        var task = findOwned(ownerId, id);
        task.setTitle(req.title().strip());
        task.setDescription(req.description());
        task.setStatus(req.status());
        log.info("Task {} updated by user {}", id, ownerId);
        return TaskResponse.from(repository.saveAndFlush(task));
    }

    public TaskResponse updateStatus(UUID ownerId, Long id, TaskStatus status) {
        var task = findOwned(ownerId, id);
        log.info("Task {} status {} -> {} by user {}", id, task.getStatus(), status, ownerId);
        task.setStatus(status);
        return TaskResponse.from(repository.saveAndFlush(task));
    }

    public void delete(UUID ownerId, Long id) {
        repository.delete(findOwned(ownerId, id));
        log.info("Task {} deleted by user {}", id, ownerId);
    }

    private Task findOwned(UUID ownerId, Long id) {
        return repository.findByIdAndOwnerId(id, ownerId).orElseThrow(() -> new TaskNotFoundException(id));
    }
}
