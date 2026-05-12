import { useState, useEffect, useCallback } from 'react'
import { isAuthenticated, setToken, clearToken, api } from '../api/client'

export function useAuth() {
  const [authed, setAuthed] = useState(isAuthenticated())
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // controllerUrl is optional: if empty, /auth/login uses the stored pairing URL
  async function login(controllerUrl: string, username: string, password: string) {
    setLoading(true)
    setError(null)
    try {
      let token: string
      if (controllerUrl.trim()) {
        // First-time or manual override: authenticate via explicit controller URL
        const res = await api.post<{ token: string }>('/auth/login-via-controller', {
          controller_url: controllerUrl.trim(),
          username,
          password,
        })
        token = res.token
      } else {
        // Post-setup: controller URL already stored in pairing table
        const res = await api.post<{ token: string }>('/auth/login', { username, password })
        token = res.token
      }
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
  const [setupDone, setSetupDone] = useState(false)
  const [checked, setChecked] = useState(false)

  const recheckSetup = useCallback(() => {
    api.get<{ setup_done: boolean }>('/auth/status')
      .then(s => {
        setNeedsSetup(!s.setup_done)
        setSetupDone(s.setup_done)
        setChecked(true)
      })
      .catch(() => { setNeedsSetup(false); setSetupDone(true); setChecked(true) })
  }, [])

  useEffect(() => { recheckSetup() }, [recheckSetup])

  return { needsSetup, setupDone, checked, recheckSetup }
}
