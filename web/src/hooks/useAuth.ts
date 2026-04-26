import { useState, useEffect, useCallback } from 'react'
import { isAuthenticated, setToken, clearToken, api } from '../api/client'

export function useAuth() {
  const [authed, setAuthed] = useState(isAuthenticated())
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function login(username: string, password: string) {
    setLoading(true)
    setError(null)
    try {
      const { token } = await api.post<{ token: string }>('/auth/login', { username, password })
      setToken(token)
      setAuthed(true)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setLoading(false)
    }
  }

  function logout() {
    clearToken()
    setAuthed(false)
  }

  return { authed, loading, error, login, logout }
}

export function useSetupStatus() {
  const [needsSetup, setNeedsSetup] = useState(false)
  const [checked, setChecked] = useState(false)

  const recheckSetup = useCallback(() => {
    api.get<{ setup_done: boolean }>('/auth/status')
      .then(s => { setNeedsSetup(!s.setup_done); setChecked(true) })
      .catch(() => { setNeedsSetup(false); setChecked(true) })
  }, [])

  useEffect(() => { recheckSetup() }, [recheckSetup])

  return { needsSetup, checked, recheckSetup }
}
