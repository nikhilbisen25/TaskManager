import type { TokenResponse, User } from '../types'
import { api } from './client'

export async function register(email: string, password: string, fullName?: string): Promise<User> {
  const { data } = await api.post<User>('/auth/register', {
    email,
    password,
    full_name: fullName || null,
  })
  return data
}

export async function login(email: string, password: string): Promise<TokenResponse> {
  const { data } = await api.post<TokenResponse>('/auth/login', { email, password })
  return data
}

export async function me(): Promise<User> {
  const { data } = await api.get<User>('/auth/me')
  return data
}
