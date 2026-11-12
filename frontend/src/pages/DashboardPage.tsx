import { useCallback, useEffect, useState } from 'react'
import { errorMessage } from '../api/client'
import { createTask, deleteTask, listTasks, updateTask, updateTaskStatus } from '../api/tasks'
import { useAuth } from '../auth/AuthContext'
import { TaskForm } from '../components/TaskForm'
import { Button, ErrorBanner, StatusBadge } from '../components/ui'
import { STATUS_LABELS, TASK_STATUSES, type Page, type Task, type TaskInput, type TaskStatus } from '../types'

const PAGE_SIZE = 10
// Set by the deploy workflow (VITE_APP_VERSION = git SHA) so you can see which commit is live.
const BUILD_VERSION = (import.meta.env.VITE_APP_VERSION ?? 'local').slice(0, 7)

export function DashboardPage() {
  const { user, logout } = useAuth()
  const [data, setData] = useState<Page<Task> | null>(null)
  const [filter, setFilter] = useState<TaskStatus | ''>('')
  const [page, setPage] = useState(0)
  const [editingId, setEditingId] = useState<number | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    try {
      setData(await listTasks({ status: filter || undefined, page, size: PAGE_SIZE }))
      setError(null)
    } catch (err) {
      setError(errorMessage(err, 'Could not load tasks'))
    } finally {
      setLoading(false)
    }
  }, [filter, page])

  useEffect(() => {
    load()
  }, [load])

  // Wrap every mutation: run it, show errors, then reload the current page.
  async function run(action: () => Promise<unknown>) {
    try {
      await action()
      setError(null)
      await load()
    } catch (err) {
      setError(errorMessage(err))
      throw err
    }
  }

  const onCreate = (input: TaskInput) => run(() => createTask(input))
  const onUpdate = (id: number) => (input: TaskInput) =>
    run(async () => {
      await updateTask(id, input)
      setEditingId(null)
    })
  const onStatus = (id: number, status: TaskStatus) => run(() => updateTaskStatus(id, status)).catch(() => {})
  const onDelete = (task: Task) => {
    if (window.confirm(`Delete "${task.title}"?`)) run(() => deleteTask(task.id)).catch(() => {})
  }

  return (
    <div className="min-h-screen">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-4 py-3">
          <h1 className="text-lg font-semibold">Task Manager</h1>
          <div className="flex items-center gap-3 text-sm">
            <span className="text-slate-600">{user?.full_name || user?.email}</span>
            <Button variant="secondary" onClick={logout}>Log out</Button>
          </div>
        </div>
      </header>

      <main className="mx-auto grid max-w-5xl gap-6 px-4 py-6 md:grid-cols-[300px_1fr]">
        <section className="h-fit rounded-2xl bg-white p-5 shadow-sm ring-1 ring-slate-200">
          <h2 className="mb-4 font-semibold">New task</h2>
          <TaskForm onSubmit={onCreate} />
        </section>

        <section>
          <div className="mb-4 flex flex-wrap items-center gap-2">
            <span className="text-sm text-slate-600">Filter:</span>
            {(['', ...TASK_STATUSES] as const).map((s) => (
              <button
                key={s || 'ALL'}
                onClick={() => {
                  setFilter(s)
                  setPage(0)
                }}
                className={`rounded-full px-3 py-1 text-sm ring-1 transition ${
                  filter === s
                    ? 'bg-indigo-600 text-white ring-indigo-600'
                    : 'bg-white text-slate-700 ring-slate-300 hover:bg-slate-50'
                }`}
              >
                {s ? STATUS_LABELS[s] : 'All'}
              </button>
            ))}
            {loading && <span className="text-sm text-slate-400">Loading…</span>}
          </div>

          <ErrorBanner message={error} />

          {data && data.content.length === 0 && (
            <p className="rounded-2xl bg-white p-8 text-center text-slate-500 ring-1 ring-slate-200">
              No tasks {filter ? `with status "${STATUS_LABELS[filter]}"` : 'yet'}.
            </p>
          )}

          <ul className="space-y-3">
            {data?.content.map((task) => (
              <li key={task.id} className="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200">
                {editingId === task.id ? (
                  <TaskForm initial={task} onSubmit={onUpdate(task.id)} onCancel={() => setEditingId(null)} />
                ) : (
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <h3 className={`font-medium ${task.status === 'DONE' ? 'text-slate-400 line-through' : ''}`}>
                          {task.title}
                        </h3>
                        <StatusBadge status={task.status} />
                      </div>
                      {task.description && (
                        <p className="mt-1 whitespace-pre-wrap text-sm text-slate-600">{task.description}</p>
                      )}
                      <p className="mt-2 text-xs text-slate-400">
                        Updated {new Date(task.updatedAt).toLocaleString()}
                      </p>
                    </div>
                    <div className="flex shrink-0 items-center gap-2">
                      <select
                        aria-label="Change status"
                        value={task.status}
                        onChange={(e) => onStatus(task.id, e.target.value as TaskStatus)}
                        className="rounded-lg border border-slate-300 bg-white px-2 py-1.5 text-sm"
                      >
                        {TASK_STATUSES.map((s) => (
                          <option key={s} value={s}>{STATUS_LABELS[s]}</option>
                        ))}
                      </select>
                      <Button variant="secondary" onClick={() => setEditingId(task.id)}>Edit</Button>
                      <Button variant="danger" onClick={() => onDelete(task)}>Delete</Button>
                    </div>
                  </div>
                )}
              </li>
            ))}
          </ul>

          {data && data.totalPages > 1 && (
            <div className="mt-4 flex items-center justify-between text-sm">
              <Button variant="secondary" disabled={page === 0} onClick={() => setPage((p) => p - 1)}>
                Previous
              </Button>
              <span className="text-slate-600">
                Page {data.page + 1} of {data.totalPages} · {data.totalElements} tasks
              </span>
              <Button variant="secondary" disabled={page + 1 >= data.totalPages} onClick={() => setPage((p) => p + 1)}>
                Next
              </Button>
            </div>
          )}
        </section>
      </main>
      <footer className="pb-6 text-center text-xs text-slate-400">
        Build {BUILD_VERSION}
      </footer>
    </div>
  )
}
