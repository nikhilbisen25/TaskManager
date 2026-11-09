package com.zifo.taskservice.task;

import java.util.Optional;
import java.util.UUID;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

/** Specifications (see {@link TaskSpecifications}) keep list filters composable: add a filter = add a spec. */
public interface TaskRepository extends JpaRepository<Task, Long>, JpaSpecificationExecutor<Task> {

    Optional<Task> findByIdAndOwnerId(Long id, UUID ownerId);
}
