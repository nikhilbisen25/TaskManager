import { useState, type FormEvent } from 'react'
import {
  PRIORITY_LABELS,
  STATUS_LABELS,
  TASK_PRIORITIES,
  TASK_STATUSES,
  type Task,
  type TaskInput,
  type TaskPriority,
  type TaskStatus,
} from '../types'
import { Button, Field } from './ui'

interface Props {
  initial?: Task
  onSubmit: (input: TaskInput) => Promise<void>
  onCancel?: () => void
}

/** Used both for "new task" and "edit task". Add new task fields here (and in types.ts). */
export function TaskForm({ initial, onSubmit, onCancel }: Props) {
  const [title, setTitle] = useState(initial?.title ?? '')
  const [description, setDescription] = useState(initial?.description ?? '')
  const [status, setStatus] = useState<TaskStatus>(initial?.status ?? 'TODO')
  const [priority, setPriority] = useState<TaskPriority>(initial?.priority ?? 'MEDIUM')
  const [dueDate, setDueDate] = useState(initial?.dueDate ?? '')
  const [submitting, setSubmitting] = useState(false)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setSubmitting(true)
    try {
      await onSubmit({
        title: title.trim(),
        description: description.trim() || null,
        status,
        priority,
        dueDate: dueDate || null,
      })
      if (!initial) {
        setTitle('')
        setDescription('')
        setStatus('TODO')
        setPriority('MEDIUM')
        setDueDate('')
      }
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <Field label="Title" required maxLength={200} value={title} onChange={(e) => setTitle(e.target.value)} />
      <label className="block">
        <span className="mb-1 block text-sm font-medium text-slate-700">Description</span>
        <textarea
          rows={3}
          maxLength={2000}
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm outline-none focus:border-indigo-500 focus:ring-2 focus:ring-indigo-200"
        />
      </label>
      <div className="grid grid-cols-2 gap-3">
        <label className="block">
          <span className="mb-1 block text-sm font-medium text-slate-700">Status</span>
          <select
            value={status}
            onChange={(e) => setStatus(e.target.value as TaskStatus)}
            className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm"
          >
            {TASK_STATUSES.map((s) => (
              <option key={s} value={s}>{STATUS_LABELS[s]}</option>
            ))}
          </select>
        </label>
        <label className="block">
          <span className="mb-1 block text-sm font-medium text-slate-700">Priority</span>
          <select
            value={priority}
            onChange={(e) => setPriority(e.target.value as TaskPriority)}
            className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm"
          >
            {TASK_PRIORITIES.map((p) => (
              <option key={p} value={p}>{PRIORITY_LABELS[p]}</option>
            ))}
          </select>
        </label>
      </div>
      <Field label="Due date (optional)" type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
      <div className="flex gap-2">
        <Button type="submit" disabled={submitting || !title.trim()}>
          {initial ? 'Save' : 'Add task'}
        </Button>
        {onCancel && (
          <Button type="button" variant="secondary" onClick={onCancel}>Cancel</Button>
        )}
      </div>
    </form>
  )
}
