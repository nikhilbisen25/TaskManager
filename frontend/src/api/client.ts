import axios, { AxiosError } from 'axios'

const TOKEN_KEY = 'tm_token'

export const tokenStore = {
  get: () => localStorage.getItem(TOKEN_KEY),
  set: (token: string) => localStorage.setItem(TOKEN_KEY, token),
  clear: () => localStorage.removeItem(TOKEN_KEY),
}

// Relative base URL: same origin everywhere (Vite proxy locally, nginx in compose, CloudFront in AWS).
export const api = axios.create({ baseURL: '/api' })

api.interceptors.request.use((config) => {
  const token = tokenStore.get()
  if (token) {
    config.headers.Authorization = `Bearer ${token}`
  }
  return config
})

// Expired or invalid token: drop it and send the user back to login.
api.interceptors.response.use(
  (res) => res,
  (error: AxiosError) => {
    const url = error.config?.url ?? ''
    const isAuthCall = url.startsWith('/auth/login') || url.startsWith('/auth/register')
    if (error.response?.status === 401 && !isAuthCall && tokenStore.get()) {
      tokenStore.clear()
      window.location.assign('/login')
    }
    return Promise.reject(error)
  },
)

/** Human-readable message from FastAPI ({detail}) or Spring ProblemDetail ({detail, errors}) errors. */
export function errorMessage(error: unknown, fallback = 'Something went wrong'): string {
  if (axios.isAxiosError(error)) {
    const data = error.response?.data as
      | { detail?: unknown; errors?: Record<string, string> }
      | undefined
    if (data?.errors && Object.keys(data.errors).length > 0) {
      return Object.entries(data.errors)
        .map(([field, msg]) => `${field}: ${msg}`)
        .join(', ')
    }
    if (typeof data?.detail === 'string') return data.detail
    // FastAPI validation errors: detail is a list of {loc, msg}
    if (Array.isArray(data?.detail)) {
      return data.detail
        .map((d: { loc?: unknown[]; msg?: string }) => `${d.loc?.slice(-1)[0] ?? ''}: ${d.msg}`)
        .join(', ')
    }
    if (!error.response) return 'Cannot reach the server'
  }
  return fallback
}
