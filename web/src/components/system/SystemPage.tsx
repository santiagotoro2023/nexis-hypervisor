import { useState, useEffect, useRef } from 'react'
import { RefreshCw, Download, CheckCircle, AlertTriangle, Terminal, Cpu } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { NxSpinner } from '../common/NxSpinner'
import { api } from '../../api/client'

interface SysInfo {
  hostname: string
  version: string
  build: string
}

interface UpdateCheck {
  up_to_date: boolean
  commits_behind: number
  current_commit: string
  latest_commit: string
  version: string
}

interface LogEntry {
  step: string
  msg: string
  ok: boolean
  ts: Date
}

type UpdateState = 'idle' | 'checking' | 'running' | 'done' | 'reconnecting' | 'error'

export function SystemPage() {
  const [info, setInfo] = useState<SysInfo | null>(null)
  const [check, setCheck] = useState<UpdateCheck | null>(null)
  const [checkLoading, setCheckLoading] = useState(false)
  const [checkError, setCheckError] = useState<string | null>(null)

  const [updateState, setUpdateState] = useState<UpdateState>('idle')
  const [log, setLog] = useState<LogEntry[]>([])
  const [countdown, setCountdown] = useState(0)
  const logRef = useRef<HTMLDivElement>(null)
  const countdownRef = useRef<ReturnType<typeof setInterval> | null>(null)

  useEffect(() => {
    api.get<SysInfo>('/system/info').then(setInfo).catch(() => {})
  }, [])

  useEffect(() => {
    if (logRef.current) {
      logRef.current.scrollTop = logRef.current.scrollHeight
    }
  }, [log])

  function appendLog(entry: Omit<LogEntry, 'ts'>) {
    setLog(prev => [...prev, { ...entry, ts: new Date() }])
  }

  async function checkForUpdates() {
    setCheckLoading(true)
    setCheckError(null)
    try {
      const result = await api.get<UpdateCheck>('/system/update/check')
      setCheck(result)
    } catch (e) {
      setCheckError((e as Error).message)
    } finally {
      setCheckLoading(false)
    }
  }

  async function applyUpdate() {
    if (updateState === 'running') return
    setLog([])
    setUpdateState('running')

    const token = sessionStorage.getItem('nx_token')
    try {
      const res = await fetch('/api/system/update', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
      })

      if (!res.ok) {
        const err = await res.json().catch(() => ({ detail: res.statusText }))
        throw new Error(err.detail || res.statusText)
      }

      const reader = res.body!.getReader()
      const decoder = new TextDecoder()
      let buf = ''

      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buf += decoder.decode(value, { stream: true })
        const parts = buf.split('\n\n')
        buf = parts.pop() ?? ''
        for (const part of parts) {
          for (const line of part.split('\n')) {
            if (!line.startsWith('data: ')) continue
            try {
              const ev = JSON.parse(line.slice(6))
              appendLog({ step: ev.step, msg: ev.msg, ok: ev.ok !== false })
              if (ev.step === 'done') {
                setUpdateState('reconnecting')
                startReconnectCountdown()
              }
            } catch { /* skip malformed */ }
          }
        }
      }
    } catch (e) {
      appendLog({ step: 'error', msg: (e as Error).message, ok: false })
      setUpdateState('error')
    }
  }

  function startReconnectCountdown() {
    let secs = 15
    setCountdown(secs)
    countdownRef.current = setInterval(() => {
      secs -= 1
      setCountdown(secs)
      if (secs <= 0) {
        clearInterval(countdownRef.current!)
        pollUntilBack()
      }
    }, 1000)
  }

  async function pollUntilBack() {
    for (let i = 0; i < 30; i++) {
      await new Promise(r => setTimeout(r, 2000))
      try {
        const d = await api.get<SysInfo>('/system/info')
        setInfo(d)
        setUpdateState('done')
        setCheck(null)
        return
      } catch { /* still down */ }
    }
    setUpdateState('error')
    appendLog({ step: 'error', msg: 'Service did not come back within 60 s — check systemd status.', ok: false })
  }

  const canUpdate = check && !check.up_to_date && updateState === 'idle'
  const isRunning = updateState === 'running' || updateState === 'reconnecting'

  return (
    <AppLayout title="System">
      <div className="space-y-6 max-w-3xl">

        {/* Node identity */}
        <div className="nx-card p-5 space-y-4">
          <div className="flex items-center gap-2 text-xs text-nx-fg2 uppercase tracking-wider">
            <Cpu size={13} strokeWidth={1.5} />
            Node Identity
          </div>
          {info ? (
            <div className="grid grid-cols-3 gap-4 text-xs">
              <div>
                <div className="text-nx-fg2 uppercase tracking-wider mb-1">Hostname</div>
                <div className="text-nx-fg font-mono">{info.hostname}</div>
              </div>
              <div>
                <div className="text-nx-fg2 uppercase tracking-wider mb-1">Version</div>
                <div className="text-nx-fg font-mono">{info.version}</div>
              </div>
              <div>
                <div className="text-nx-fg2 uppercase tracking-wider mb-1">Build</div>
                <div className="text-nx-fg font-mono">{info.build}</div>
              </div>
            </div>
          ) : (
            <div className="flex items-center gap-2 text-nx-fg2 text-xs">
              <NxSpinner size={12} /> Loading...
            </div>
          )}
        </div>

        {/* Update check */}
        <div className="nx-card p-5 space-y-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2 text-xs text-nx-fg2 uppercase tracking-wider">
              <Download size={13} strokeWidth={1.5} />
              Software Update
            </div>
            <button
              className="nx-btn-ghost text-xs flex items-center gap-1.5"
              onClick={checkForUpdates}
              disabled={checkLoading || isRunning}
            >
              {checkLoading ? <NxSpinner size={12} /> : <RefreshCw size={12} />}
              CHECK
            </button>
          </div>

          {checkError && (
            <div className="text-nx-red text-xs flex items-center gap-1.5">
              <AlertTriangle size={12} /> {checkError}
            </div>
          )}

          {check && (
            <div className="space-y-3">
              {check.up_to_date ? (
                <div className="flex items-center gap-2 text-nx-green text-xs">
                  <CheckCircle size={13} />
                  <span className="uppercase tracking-wider">Up to date</span>
                  <span className="text-nx-fg2 font-mono">({check.current_commit})</span>
                </div>
              ) : (
                <div className="space-y-2">
                  <div className="flex items-center gap-2 text-nx-yellow text-xs">
                    <AlertTriangle size={13} />
                    <span className="uppercase tracking-wider">{check.commits_behind} commit{check.commits_behind !== 1 ? 's' : ''} behind origin/main</span>
                  </div>
                  <div className="grid grid-cols-2 gap-4 text-xs">
                    <div>
                      <div className="text-nx-fg2 uppercase tracking-wider mb-0.5">Current</div>
                      <div className="text-nx-fg font-mono">{check.current_commit}</div>
                    </div>
                    <div>
                      <div className="text-nx-fg2 uppercase tracking-wider mb-0.5">Latest</div>
                      <div className="text-nx-fg font-mono">{check.latest_commit}</div>
                    </div>
                  </div>
                </div>
              )}
            </div>
          )}

          {!check && !checkLoading && (
            <div className="text-nx-fg2 text-xs">Run a check to compare against origin/main.</div>
          )}

          <button
            className={`nx-btn-primary flex items-center gap-2 w-full justify-center ${!canUpdate ? 'opacity-40 cursor-not-allowed' : ''}`}
            onClick={canUpdate ? applyUpdate : undefined}
            disabled={!canUpdate}
          >
            {isRunning ? <NxSpinner size={14} /> : <Download size={14} />}
            {updateState === 'running' ? 'UPDATING...' :
             updateState === 'reconnecting' ? `RESTARTING — RECONNECT IN ${countdown}s` :
             updateState === 'done' ? 'UPDATE COMPLETE' :
             'APPLY UPDATE'}
          </button>
        </div>

        {/* Update log */}
        {log.length > 0 && (
          <div className="nx-card overflow-hidden">
            <div className="px-5 py-3 border-b border-nx-border flex items-center gap-2 text-xs text-nx-fg2 uppercase tracking-wider">
              <Terminal size={12} />
              Update Log
            </div>
            <div
              ref={logRef}
              className="p-4 font-mono text-xs space-y-1 max-h-80 overflow-y-auto bg-nx-bg"
            >
              {log.map((entry, i) => (
                <div key={i} className="flex gap-3">
                  <span className="text-nx-fg2 shrink-0 select-none">
                    {entry.ts.toLocaleTimeString('en-GB', { hour12: false })}
                  </span>
                  <span className={
                    entry.step === 'error' || !entry.ok ? 'text-nx-red' :
                    entry.step === 'done' ? 'text-nx-green' :
                    entry.step === 'start' ? 'text-nx-orange' :
                    'text-nx-fg'
                  }>
                    {entry.msg}
                  </span>
                </div>
              ))}
              {updateState === 'reconnecting' && (
                <div className="flex gap-3">
                  <span className="text-nx-fg2 shrink-0 select-none">
                    {new Date().toLocaleTimeString('en-GB', { hour12: false })}
                  </span>
                  <span className="text-nx-yellow animate-pulse">
                    Waiting for service to restart... ({countdown}s)
                  </span>
                </div>
              )}
              {updateState === 'done' && (
                <div className="flex gap-3">
                  <span className="text-nx-fg2 shrink-0 select-none">──────────</span>
                  <span className="text-nx-green uppercase tracking-wider">Service restored. Reload to apply changes.</span>
                </div>
              )}
            </div>
            {updateState === 'done' && (
              <div className="px-5 py-3 border-t border-nx-border">
                <button
                  className="nx-btn-primary text-xs flex items-center gap-2"
                  onClick={() => window.location.reload()}
                >
                  <RefreshCw size={12} /> Reload Interface
                </button>
              </div>
            )}
          </div>
        )}

      </div>
    </AppLayout>
  )
}
