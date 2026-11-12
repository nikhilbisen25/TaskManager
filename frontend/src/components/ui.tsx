import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode } from 'react'
import { PRIORITY_LABELS, STATUS_LABELS, type TaskPriority, type TaskStatus } from '../types'

// Small shared Tailwind building blocks so pages stay readable.

export function AuthCard({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="flex min-h-screen items-center justify-center px-4">
      <div className="w-full max-w-sm rounded-2xl bg-white p-8 shadow-sm ring-1 ring-slate-200">
        <h1 className="mb-6 text-2xl font-semibold tracking-tight">{title}</h1>
        {children}
      </div>
    </div>
  )
}

export function Field({ label, ...props }: { label: string } & InputHTMLAttributes<HTMLInputElement>) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm font-medium text-slate-700">{label}</span>
      <input
        {...props}
        className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm outline-none focus:border-indigo-500 focus:ring-2 focus:ring-indigo-200"
      />
    </label>
  )
}

type Variant = 'primary' | 'secondary' | 'danger'
const VARIANTS: Record<Variant, string> = {
  primary: 'bg-indigo-600 text-white hover:bg-indigo-700',
  secondary: 'bg-white text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50',
  danger: 'bg-white text-red-600 ring-1 ring-red-200 hover:bg-red-50',
}

export function Button({
  variant = 'primary',
  className = '',
  ...props
}: { variant?: Variant } & ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button
      {...props}
      className={`rounded-lg px-3 py-2 text-sm font-medium transition disabled:cursor-not-allowed disabled:opacity-50 ${VARIANTS[variant]} ${className}`}
    />
  )
}

export function ErrorBanner({ message }: { message: string | null }) {
  if (!message) return null
  return (
    <p role="alert" className="mb-4 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 ring-1 ring-red-200">
      {message}
    </p>
  )
}

const BADGE: Record<TaskStatus, string> = {
  TODO: 'bg-slate-100 text-slate-700',
  IN_PROGRESS: 'bg-amber-100 text-amber-800',
  DONE: 'bg-emerald-100 text-emerald-800',
}

const PRIORITY_BADGE: Record<TaskPriority, string> = {
  LOW: 'bg-sky-50 text-sky-700 ring-1 ring-sky-200',
  MEDIUM: 'bg-violet-50 text-violet-700 ring-1 ring-violet-200',
  HIGH: 'bg-red-50 text-red-700 ring-1 ring-red-200',
}

export function PriorityBadge({ priority }: { priority: TaskPriority }) {
  return (
    <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${PRIORITY_BADGE[priority]}`}>
      {PRIORITY_LABELS[priority]}
    </span>
  )
}

export function StatusBadge({ status }: { status: TaskStatus }) {
  return (
    <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${BADGE[status]}`}>
      {STATUS_LABELS[status]}
    </span>
  )
}
