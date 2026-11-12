package com.zifo.taskservice.task;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.LocalDate;
import java.util.Optional;
import java.util.UUID;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import com.zifo.taskservice.task.dto.TaskDtos.CreateTaskRequest;
import com.zifo.taskservice.task.dto.TaskDtos.UpdateTaskRequest;

@ExtendWith(MockitoExtension.class)
class TaskServiceTest {

    private static final UUID OWNER = UUID.randomUUID();
    private static final UUID OTHER_USER = UUID.randomUUID();

    @Mock
    TaskRepository repository;

    @InjectMocks
    TaskService service;

    @Test
    void createSetsOwnerFromCallerAndDefaultsStatusToTodo() {
        when(repository.save(any(Task.class))).thenAnswer(inv -> inv.getArgument(0));

        var result = service.create(OWNER, new CreateTaskRequest("  Buy milk  ", null, null));

        var captor = ArgumentCaptor.forClass(Task.class);
        verify(repository).save(captor.capture());
        assertThat(captor.getValue().getOwnerId()).isEqualTo(OWNER);
        assertThat(result.title()).isEqualTo("Buy milk");
        assertThat(result.status()).isEqualTo(TaskStatus.TODO);
        assertThat(result.priority()).isEqualTo(TaskPriority.MEDIUM);
        assertThat(result.dueDate()).isNull();
    }

    @Test
    void createStoresPriorityAndDueDate() {
        when(repository.save(any(Task.class))).thenAnswer(inv -> inv.getArgument(0));
        var due = LocalDate.of(2026, 11, 20);

        var result = service.create(OWNER, new CreateTaskRequest("Ship", null, null, TaskPriority.HIGH, due));

        assertThat(result.priority()).isEqualTo(TaskPriority.HIGH);
        assertThat(result.dueDate()).isEqualTo(due);
    }

    @Test
    void updateWithoutPriorityKeepsCurrentPriorityAndClearsDueDate() {
        var task = new Task();
        task.setId(9L);
        task.setOwnerId(OWNER);
        task.setTitle("Old");
        task.setPriority(TaskPriority.HIGH);
        task.setDueDate(LocalDate.of(2026, 11, 20));
        when(repository.findByIdAndOwnerId(9L, OWNER)).thenReturn(Optional.of(task));
        when(repository.saveAndFlush(task)).thenReturn(task);

        // An older client (e.g. scripts/smoke-test.sh) sends no priority and no dueDate.
        var result = service.update(OWNER, 9L, new UpdateTaskRequest("New", null, TaskStatus.IN_PROGRESS, null, null));

        assertThat(result.priority()).isEqualTo(TaskPriority.HIGH);
        assertThat(result.dueDate()).isNull();
        assertThat(result.title()).isEqualTo("New");
    }

    @Test
    void updateStatusChangesOnlyStatus() {
        var task = new Task();
        task.setId(7L);
        task.setOwnerId(OWNER);
        task.setTitle("Ship it");
        when(repository.findByIdAndOwnerId(7L, OWNER)).thenReturn(Optional.of(task));
        when(repository.saveAndFlush(task)).thenReturn(task);

        var result = service.updateStatus(OWNER, 7L, TaskStatus.DONE);

        assertThat(result.status()).isEqualTo(TaskStatus.DONE);
        assertThat(result.title()).isEqualTo("Ship it");
    }

    @Test
    void anotherUsersTaskLooksLikeNotFound() {
        when(repository.findByIdAndOwnerId(7L, OTHER_USER)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.delete(OTHER_USER, 7L)).isInstanceOf(TaskNotFoundException.class);
        verify(repository, never()).delete(any(Task.class));
    }
}
