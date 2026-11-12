import type { Page, Task, TaskInput, TaskPriority, TaskStatus } from '../types'
import { api } from './client'

export interface TaskQuery {
  status?: TaskStatus
  priority?: TaskPriority
  dueBefore?: string // yyyy-MM-dd, inclusive
  page?: number
  size?: number
}

export async function listTasks(query: TaskQuery = {}): Promise<Page<Task>> {
  const { data } = await api.get<Page<Task>>('/tasks', {
    params: {
      status: query.status,
      priority: query.priority,
      dueBefore: query.dueBefore,
      page: query.page ?? 0,
      size: query.size ?? 10,
      sort: 'createdAt,desc',
    },
  })
  return data
}

export async function createTask(input: TaskInput): Promise<Task> {
  const { data } = await api.post<Task>('/tasks', input)
  return data
}

export async function updateTask(id: number, input: TaskInput): Promise<Task> {
  const { data } = await api.put<Task>(`/tasks/${id}`, input)
  return data
}

export async function updateTaskStatus(id: number, status: TaskStatus): Promise<Task> {
  const { data } = await api.patch<Task>(`/tasks/${id}/status`, { status })
  return data
}

export async function deleteTask(id: number): Promise<void> {
  await api.delete(`/tasks/${id}`)
}
