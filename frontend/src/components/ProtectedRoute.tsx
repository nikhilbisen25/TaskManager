import type { ReactNode } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'

export function ProtectedRoute({ children }: { children: ReactNode }) {
  const { user, loading } = useAuth()
  if (loading) {
    return <p className="p-8 text-center text-slate-500">Loading…</p>
  }
  return user ? <>{children}</> : <Navigate to="/login" replace />
}
