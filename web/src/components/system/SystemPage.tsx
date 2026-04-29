import { useState, useEffect, useRef } from 'react'
import { RefreshCw, Download, CheckCircle, AlertTriangle, Terminal, Cpu,
         Network, Plus, Trash2, ExternalLink } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { NxSpinner } from '../common/NxSpinner'
import { NxModal } from '../common/NxModal'
import { api } from '../../api/client'
import { useNavigate } from 'react-router-dom'

interface SysInfo { hostname: string; version: string; build: string }
interface UpdateCheck {
  up_to_date: boolean; commits_behind: number
  current_commit: string; latest_commit: string; version: string
}
interface LogEntry { step: string; msg: string; ok: boolean; ts: Date }
interface ClusterNode { node_id: string; name: string; url: string; role: string; last_seen: string }
type UpdateState = 'idle' | 'checking' | 'running' | 'done' | 'reconnecting' | 'error'

export function SystemPage() {
  const [info, setInfo] = useState<SysInfo | null>(null)
  const [check, setCheck] = useState<UpdateCheck | null>(null)
  const [checkLoading, setCheckLoading] = useState(false)
  const [checkError, setCheckError] = useState<string | null>(null)
  const [updateState, setUpdateState] = useState<UpdateState>('idle')
  const [log, setLog] = useState<LogEntry[]>([])
  const [countdown, setCountdown] = useState(0)
  const [nodes, setNodes] = useState<ClusterNode[]>([])
  const [showAddNode, setShowAddNode] = useState(false)
  const [nodeForm, setNodeForm] = useState({ name: '', url: '', api_token: '', role: 'worker' })
  const [addingNode, setAddingNode] = useState(false)
  const [addNodeError, setAddNodeError] = useState<string | null>(null)
  const logRef = useRef<HTMLDivElement>(null)
  const countdownRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const navigate = useNavigate()

  useEffect(() => { api.get<SysInfo>('/system/info').then(setInfo).catch(() => {}) }, [])
  useEffect(() => { fetchNodes() }, [])

  useEffect(() => {
    if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight
  }, [log])

  function fetchNodes() {
    api.get<{ nodes: ClusterNode[] }>('/cluster/nodes')
      .then(d => setNodes(d.nodes ?? []))
      .catch(() => {})
  }

  function appendLog(entry: Omit<LogEntry, 'ts'>) {
    setLog(prev => [...prev, { ...entry, ts: new Date() }])
  }

  async function checkForUpdates() {
    setCheckLoading(true); setCheckError(null)
    try { setCheck(await api.get<UpdateCheck>('/system/update/check')) }
    catch (e) { setCheckError((e as Error).message) }
    finally { setCheckLoading(false) }
  }

  async function applyUpdate() {
    if (updateState === 'running') return
    setLog([]); setUpdateState('running')
    const token = sessionStorage.getItem('nx_token')
    try {
      const res = await fetch('/api/system/update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      })
      if (!res.ok) {
        const err = await res.json().catch(() => ({ detail: res.statusText }))
        throw new Error(err.detail || res.statusText)
      }
      const reader = res.body!.getReader(); const decoder = new TextDecoder(); let buf = ''
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buf += decoder.decode(value, { stream: true })
        const parts = buf.split('\n\n'); buf = parts.pop() ?? ''
        for (const part of parts)
          for (const line of part.split('\n')) {
            if (!line.startsWith('data: ')) continue
            try {
              const ev = JSON.parse(line.slice(6))
              appendLog({ step: ev.step, msg: ev.msg, ok: ev.ok !== false })
              if (ev.step === 'done') { setUpdateState('reconnecting'); startReconnectCountdown() }
            } catch { /* skip */ }
          }
      }
    } catch (e) { appendLog({ step: 'error', msg: (e as Error).message, ok: false }); setUpdateState('error') }
  }

  function startReconnectCountdown() {
    let secs = 15; setCountdown(secs)
    countdownRef.current = setInterval(() => {
      secs -= 1; setCountdown(secs)
      if (secs <= 0) { clearInterval(countdownRef.current!); pollUntilBack() }
    }, 1000)
  }

  async function pollUntilBack() {
    for (let i = 0; i < 30; i++) {
      await new Promise(r => setTimeout(r, 2000))
      try { setInfo(await api.get<SysInfo>('/system/info')); setUpdateState('done'); setCheck(null); return }
      catch { /* still down */ }
    }
    setUpdateState('error')
    appendLog({ step: 'error', msg: 'Service did not come back within 60s — check systemd status.', ok: false })
  }

  async function addNode() {
    if (!nodeForm.name.trim() || !nodeForm.url.trim()) { setAddNodeError('Name and URL are required'); return }
    setAddingNode(true); setAddNodeError(null)
    try {
      await api.post('/cluster/nodes/join', nodeForm)
      setShowAddNode(false)
      setNodeForm({ name: '', url: '', api_token: '', role: 'worker' })
      fetchNodes()
    } catch (e) { setAddNodeError((e as Error).message) }
    finally { setAddingNode(false) }
  }

  async function removeNode(id: string, name: string) {
    if (!confirm(`Remove node "${name}"?`)) return
    await api.delete(`/cluster/nodes/${id}`).catch(() => {})
    fetchNodes()
  }

  const canUpdate = check && !check.up_to_date && updateState === 'idle'
  const isRunning = updateState === 'running' || updateState === 'reconnecting'

  return (
    <AppLayout title="System">
      <div className="space-y-6 max-w-3xl">

        {/* Node identity */}
        <div className="nx-card p-5 space-y-4">
          <div className="flex items-center gap-2 text-xs text-nx-fg2 uppercase tracking-wider">
            <Cpu size={13} strokeWidth={1.5} /> Node Identity
          </div>
          {info ? (
            <div className="grid grid-cols-3 gap-4 text-xs">
              {[['Hostname', info.hostname], ['Version', info.version], ['Build', info.build]].map(([k, v]) => (
                <div key={k}>
                  <div className="text-nx-fg2 uppercase tracking-wider mb-1">{k}</div>
                  <div className="text-nx-fg font-mono">{v}</div>
                </div>
              ))}
            </div>
          ) : <div className="flex items-center gap-2 text-nx-fg2 text-xs"><NxSpinner size={12} /> Loading...</div>}
        </div>

        {/* Cluster nodes */}
        <div className="nx-card overflow-hidden">
          <div className="flex items-center justify-between px-5 py-3 border-b border-nx-border">
            <div className="flex items-center gap-2 text-xs text-nx-fg2 uppercase tracking-wider">
              <Network size={13} strokeWidth={1.5} /> Cluster Nodes
            </div>
            <button className="nx-btn-ghost flex items-center gap-1.5 text-xs" onClick={() => setShowAddNode(true)}>
              <Plus size={12} /> Add Node
            </button>
          </div>
          {nodes.length === 0 ? (
            <div className="px-5 py-6 text-xs text-nx-fg2">No remote nodes registered.</div>
          ) : (
            <table className="w-full text-xs">
              <thead>
                <tr className="border-b border-nx-border text-[10px] text-nx-fg2 uppercase tracking-[0.2em]">
                  <th className="text-left px-5 py-2">Name</th>
                  <th className="text-left px-4 py-2">URL</th>
                  <th className="text-left px-4 py-2">Role</th>
                  <th className="text-right px-5 py-2">Actions</th>
                </tr>
              </thead>
              <tbody>
                {nodes.map(node => (
                  <tr key={node.node_id} className="border-b border-nx-border/40 hover:bg-nx-dim/20">
                    <td className="px-5 py-2.5 font-mono text-nx-fg">{node.name}</td>
                    <td className="px-4 py-2.5 text-nx-fg2 font-mono">{node.url}</td>
                    <td className="px-4 py-2.5 text-nx-fg2 uppercase">{node.role}</td>
                    <td className="px-5 py-2.5">
                      <div className="flex items-center justify-end gap-1">
                        <button
                          title="Open SSH Shell"
                          className="nx-btn-ghost p-1.5 flex items-center gap-1"
                          onClick={() => navigate(`/nodes/${node.node_id}/shell`)}
                        >
                          <Terminal size={12} className="text-nx-orange" />
                        </button>
                        <a
                          href={node.url}
                          target="_blank"
                          rel="noreferrer"
                          className="nx-btn-ghost p-1.5 flex items-center"
                          title="Open node UI"
                        >
                          <ExternalLink size={12} />
                        </a>
                        <button
                          title="Remove node"
                          className="nx-btn-ghost p-1.5"
                          onClick={() => removeNode(node.node_id, node.name)}
                        >
                          <Trash2 size={12} className="text-nx-red/60 hover:text-nx-red" />
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>

        {/* Software update */}
        <div className="nx-card p-5 space-y-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2 text-xs text-nx-fg2 uppercase tracking-wider">
              <Download size={13} strokeWidth={1.5} /> Software Update
            </div>
            <button className="nx-btn-ghost text-xs flex items-center gap-1.5" onClick={checkForUpdates}
              disabled={checkLoading || isRunning}>
              {checkLoading ? <NxSpinner size={12} /> : <RefreshCw size={12} />} CHECK
            </button>
          </div>
          {checkError && <div className="text-nx-red text-xs flex items-center gap-1.5"><AlertTriangle size={12} />{checkError}</div>}
          {check && (
            check.up_to_date ? (
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
                  {[['Current', check.current_commit], ['Latest', check.latest_commit]].map(([k, v]) => (
                    <div key={k}>
                      <div className="text-nx-fg2 uppercase tracking-wider mb-0.5">{k}</div>
                      <div className="text-nx-fg font-mono">{v}</div>
                    </div>
                  ))}
                </div>
              </div>
            )
          )}
          {!check && !checkLoading && <div className="text-nx-fg2 text-xs">Run a check to compare against origin/main.</div>}
          <button
            className={`nx-btn-primary flex items-center gap-2 w-full justify-center ${!canUpdate ? 'opacity-40 cursor-not-allowed' : ''}`}
            onClick={canUpdate ? applyUpdate : undefined} disabled={!canUpdate}
          >
            {isRunning ? <NxSpinner size={14} /> : <Download size={14} />}
            {updateState === 'running' ? 'UPDATING...' :
             updateState === 'reconnecting' ? `RESTARTING — RECONNECT IN ${countdown}s` :
             updateState === 'done' ? 'UPDATE COMPLETE' : 'APPLY UPDATE'}
          </button>
        </div>

        {/* Update log */}
        {log.length > 0 && (
          <div className="nx-card overflow-hidden">
            <div className="px-5 py-3 border-b border-nx-border flex items-center gap-2 text-xs text-nx-fg2 uppercase tracking-wider">
              <Terminal size={12} /> Update Log
            </div>
            <div ref={logRef} className="p-4 font-mono text-xs space-y-1 max-h-80 overflow-y-auto bg-nx-bg">
              {log.map((entry, i) => (
                <div key={i} className="flex gap-3">
                  <span className="text-nx-fg2 shrink-0 select-none">
                    {entry.ts.toLocaleTimeString('en-GB', { hour12: false })}
                  </span>
                  <span className={
                    entry.step === 'error' || !entry.ok ? 'text-nx-red' :
                    entry.step === 'done' ? 'text-nx-green' :
                    entry.step === 'start' ? 'text-nx-orange' : 'text-nx-fg'
                  }>{entry.msg}</span>
                </div>
              ))}
              {updateState === 'reconnecting' && (
                <div className="flex gap-3">
                  <span className="text-nx-fg2 shrink-0">──────────</span>
                  <span className="text-nx-yellow animate-pulse">Waiting for service to restart... ({countdown}s)</span>
                </div>
              )}
              {updateState === 'done' && (
                <div className="flex gap-3">
                  <span className="text-nx-fg2 shrink-0">──────────</span>
                  <span className="text-nx-green uppercase tracking-wider">Service restored. Reload to apply changes.</span>
                </div>
              )}
            </div>
            {updateState === 'done' && (
              <div className="px-5 py-3 border-t border-nx-border">
                <button className="nx-btn-primary text-xs flex items-center gap-2" onClick={() => window.location.reload()}>
                  <RefreshCw size={12} /> Reload Interface
                </button>
              </div>
            )}
          </div>
        )}
      </div>

      {/* Add node modal */}
      {showAddNode && (
        <NxModal title="Add Cluster Node" onClose={() => setShowAddNode(false)} width="max-w-md">
          <div className="space-y-4">
            <div>
              <label className="nx-label">Node Name</label>
              <input className="nx-input" placeholder="node-01" value={nodeForm.name}
                onChange={e => setNodeForm(f => ({ ...f, name: e.target.value }))} autoFocus />
            </div>
            <div>
              <label className="nx-label">Node URL</label>
              <input className="nx-input font-mono" placeholder="https://192.168.1.x:8443"
                value={nodeForm.url}
                onChange={e => setNodeForm(f => ({ ...f, url: e.target.value }))} />
            </div>
            <div>
              <label className="nx-label">API Token <span className="normal-case opacity-50">(optional)</span></label>
              <input className="nx-input font-mono" placeholder="bearer token"
                value={nodeForm.api_token}
                onChange={e => setNodeForm(f => ({ ...f, api_token: e.target.value }))} />
            </div>
            <div>
              <label className="nx-label">Role</label>
              <select className="nx-input" value={nodeForm.role}
                onChange={e => setNodeForm(f => ({ ...f, role: e.target.value }))}>
                <option value="worker">Worker</option>
                <option value="primary">Primary</option>
              </select>
            </div>
            {addNodeError && <div className="text-nx-red text-xs">{addNodeError}</div>}
            <div className="flex justify-end gap-3 pt-1">
              <button className="nx-btn-ghost" onClick={() => setShowAddNode(false)}>Cancel</button>
              <button className="nx-btn-primary flex items-center gap-2" onClick={addNode} disabled={addingNode}>
                {addingNode && <NxSpinner size={13} />} Add Node
              </button>
            </div>
          </div>
        </NxModal>
      )}
    </AppLayout>
  )
}
