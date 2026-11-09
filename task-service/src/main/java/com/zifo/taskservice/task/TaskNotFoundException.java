package com.zifo.taskservice.task;

/** Thrown when a task does not exist OR belongs to another user (we never reveal which). */
public class TaskNotFoundException extends RuntimeException {

    public TaskNotFoundException(Long id) {
        super("Task " + id + " not found");
    }
}
