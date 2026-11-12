// Mirrors the backend DTOs. Keep in sync with task-service TaskDtos.java and auth-service schemas.py.

export type TaskStatus = 'TODO' | 'IN_PROGRESS' | 'DONE'

export const TASK_STATUSES: TaskStatus[] = ['TODO', 'IN_PROGRESS', 'DONE']

export const STATUS_LABELS: Record<TaskStatus, string> = {
  TODO: 'To do',
  IN_PROGRESS: 'In progress',
  DONE: 'Done',
}

export type TaskPriority = 'LOW' | 'MEDIUM' | 'HIGH'

export const TASK_PRIORITIES: TaskPriority[] = ['LOW', 'MEDIUM', 'HIGH']

export const PRIORITY_LABELS: Record<TaskPriority, string> = {
  LOW: 'Low',
  MEDIUM: 'Medium',
  HIGH: 'High',
}

export interface Task {
  id: number
  title: string
  description: string | null
  status: TaskStatus
  priority: TaskPriority
  dueDate: string | null // yyyy-MM-dd
  createdAt: string
  updatedAt: string
}

export interface TaskInput {
  title: string
  description: string | null
  status: TaskStatus
  priority: TaskPriority
  dueDate: string | null
}

export interface Page<T> {
  content: T[]
  page: number
  size: number
  totalElements: number
  totalPages: number
}

export interface User {
  id: string
  email: string
  full_name: string | null
  created_at: string
}

export interface TokenResponse {
  access_token: string
  token_type: string
  expires_in: number
}
