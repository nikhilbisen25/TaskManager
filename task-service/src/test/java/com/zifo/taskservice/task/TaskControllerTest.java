package com.zifo.taskservice.task;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.http.MediaType;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import com.zifo.taskservice.config.SecurityConfig;
import com.zifo.taskservice.task.dto.TaskDtos.CreateTaskRequest;
import com.zifo.taskservice.task.dto.TaskDtos.TaskResponse;

@WebMvcTest(TaskController.class)
@Import(SecurityConfig.class)
class TaskControllerTest {

    private static final UUID OWNER = UUID.fromString("11111111-1111-1111-1111-111111111111");

    @Autowired
    MockMvc mvc;

    @MockitoBean
    TaskService service;

    @MockitoBean
    JwtDecoder jwtDecoder; // the jwt() post-processor bypasses decoding; this just satisfies the context

    private static TaskResponse sample(Long id, TaskStatus status) {
        var now = Instant.parse("2026-11-09T10:00:00Z");
        return new TaskResponse(id, "Write tests", "desc", status, now, now);
    }

    @Test
    void requestsWithoutTokenAreRejected() throws Exception {
        mvc.perform(get("/api/tasks")).andExpect(status().isUnauthorized());
    }

    @Test
    void createUsesOwnerFromTokenAndReturns201() throws Exception {
        when(service.create(eq(OWNER), any(CreateTaskRequest.class))).thenReturn(sample(42L, TaskStatus.TODO));

        mvc.perform(post("/api/tasks")
                        .with(jwt().jwt(j -> j.subject(OWNER.toString())))
                        .contentType(MediaType.APPLICATION_JSON)
                        // ownerId in the body must be ignored: it is not even part of the DTO
                        .content("""
                                {"title":"Write tests","description":"desc",
                                 "ownerId":"22222222-2222-2222-2222-222222222222"}"""))
                .andExpect(status().isCreated())
                .andExpect(header().string("Location", "/api/tasks/42"))
                .andExpect(jsonPath("$.id").value(42))
                .andExpect(jsonPath("$.status").value("TODO"));

        verify(service).create(eq(OWNER), any(CreateTaskRequest.class));
    }

    @Test
    void blankTitleReturnsProblemDetailWithFieldErrors() throws Exception {
        mvc.perform(post("/api/tasks")
                        .with(jwt().jwt(j -> j.subject(OWNER.toString())))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"title\":\"  \"}"))
                .andExpect(status().isBadRequest())
                .andExpect(header().string("Content-Type", "application/problem+json"))
                .andExpect(jsonPath("$.title").value("Invalid request"))
                .andExpect(jsonPath("$.errors.title").exists());

        verify(service, never()).create(any(), any());
    }

    @Test
    void listPassesStatusFilterAndReturnsPage() throws Exception {
        when(service.list(eq(OWNER), eq(TaskStatus.DONE), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(sample(1L, TaskStatus.DONE)), PageRequest.of(0, 20), 1));

        mvc.perform(get("/api/tasks").param("status", "DONE")
                        .with(jwt().jwt(j -> j.subject(OWNER.toString()))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.content[0].status").value("DONE"))
                .andExpect(jsonPath("$.totalElements").value(1))
                .andExpect(jsonPath("$.page").value(0));
    }

    @Test
    void invalidStatusFilterReturns400() throws Exception {
        mvc.perform(get("/api/tasks").param("status", "NOPE")
                        .with(jwt().jwt(j -> j.subject(OWNER.toString()))))
                .andExpect(status().isBadRequest());
    }

    @Test
    void unknownTaskReturns404ProblemDetail() throws Exception {
        when(service.updateStatus(OWNER, 99L, TaskStatus.DONE)).thenThrow(new TaskNotFoundException(99L));

        mvc.perform(patch("/api/tasks/99/status")
                        .with(jwt().jwt(j -> j.subject(OWNER.toString())))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"status\":\"DONE\"}"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.title").value("Task not found"));
    }
}
