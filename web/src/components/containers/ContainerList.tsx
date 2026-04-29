import { useState, useEffect, useRef, useCallback } from 'react'
import { Plus, Play, Square, RotateCcw, Trash2, Terminal, RefreshCw, AlertTriangle } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { StatusBadge } from '../common/StatusBadge'
import { NxSpinner } from '../common/NxSpinner'
import { NxModal } from '../common/NxModal'
import { api } from '../../api/client'
import { Container, CreateContainerPayload } from './types'
import { CreateContainerForm } from './CreateContainerForm'
import { useNavigate } from 'react-router-dom'

interface ContextMenu { x: number; y: number; ct: Container }
interface DeleteConfirm { ct: Container }

const CREATE_STEPS = [
  'Resolving template…', 'Downloading rootfs…', 'Extracting filesystem…',
  'Configuring container…', 'Applying resource limits…', 'Setting credentials…', 'Finalising…',
]

export function ContainerList() {
  const [containers, setContainers] = useState<Container[]>([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [creating, setCreating] = useState(false)
  const [createStep, setCreateStep] = useState(0)
  const [acting, setActing] = useState<string | null>(null)
  const [contextMenu, setContextMenu] = useState<ContextMenu | null>(null)
  const [deleteConfirm, setDeleteConfirm] = useState<DeleteConfirm | null>(null)
  const [deleteInput, setDeleteInput] = useState('')
  const [deleting, setDeleting] = useState(false)
  const menuRef = useRef<HTMLDivElement>(null)
  const stepInterval = useRef<ReturnType<typeof setInterval> | null>(null)
  const navigate = useNavigate()

  const fetchContainers = useCallback(() =>
    api.get<Container[]>('/containers').then(setContainers).finally(() => setLoading(false)), [])

  useEffect(() => { fetchContainers() }, [fetchContainers])

  useEffect(() => {
    function onClickOutside(e: MouseEvent) {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) setContextMenu(null)
    }
    if (contextMenu) {
      document.addEventListener('mousedown', onClickOutside)
      return () => document.removeEventListener('mousedown', onClickOutside)
    }
  }, [contextMenu])

  async function action(id: string, op: string) {
    setContextMenu(null); setActing(id)
    try { await api.post(`/containers/${id}/${op}`) }
    finally { setActing(null); fetchContainers() }
  }

  function promptDelete(ct: Container) {
    setContextMenu(null)
    setDeleteInput('')
    setDeleteConfirm({ ct })
  }

  async function confirmDelete() {
    if (!deleteConfirm) return
    setDeleting(true)
    try {
      await api.delete(`/containers/${deleteConfirm.ct.id}`)
      setDeleteConfirm(null)
    } finally {
      setDeleting(false)
      fetchContainers()
    }
  }

  async function handleCreate(payload: CreateContainerPayload) {
    setShowCreate(false); setCreating(true); setCreateStep(0)
    stepInterval.current = setInterval(() => setCreateStep(s => Math.min(s + 1, CREATE_STEPS.length - 1)), 2200)
    try { await api.post('/containers', payload) }
    finally {
      if (stepInterval.current) clearInterval(stepInterval.current)
      stepInterval.current = null
      setCreating(false); setCreateStep(0); fetchContainers()
    }
  }

  function openContextMenu(e: React.MouseEvent, ct: Container) {
    e.preventDefault(); e.stopPropagation()
    setContextMenu({ x: e.clientX, y: e.clientY, ct })
  }

  const running = (ct: Container) => ct.status === 'running'
  const stopped = (ct: Container) => ct.status === 'stopped'
  const paused  = (ct: Container) => ct.status === 'paused'

  return (
    <AppLayout title="Containers">
      <div className="space-y-4">
        <div className="flex items-center justify-between">
          <p className="text-xs text-nx-fg2 tracking-wider">
            {containers.length} container{containers.length !== 1 ? 's' : ''}
          </p>
          <button className="nx-btn-primary flex items-center gap-2 text-xs tracking-wider"
            onClick={() => setShowCreate(true)}>
            <Plus size={13} /> Create Container
          </button>
        </div>

        {creating && (
          <div className="nx-card p-5">
            <div className="flex items-center gap-3 mb-3">
              <NxSpinner size={18} />
              <span className="text-xs text-nx-orange tracking-widest uppercase font-mono">Provisioning Container</span>
            </div>
            <div className="text-xs text-nx-fg2 mb-3 h-4">{CREATE_STEPS[createStep]}</div>
            <div className="w-full h-1 bg-nx-dim rounded-full overflow-hidden">
              <div className="h-full bg-nx-orange rounded-full transition-all duration-700"
                style={{ width: `${((createStep + 1) / CREATE_STEPS.length) * 100}%` }} />
            </div>
            <div className="text-[10px] text-nx-fg2 mt-1.5 text-right font-mono">
              {Math.round(((createStep + 1) / CREATE_STEPS.length) * 100)}%
            </div>
          </div>
        )}

        <div className="nx-card overflow-hidden">
          {loading ? (
            <div className="flex items-center justify-center py-16"><NxSpinner size={24} /></div>
          ) : containers.length === 0 ? (
            <div className="py-16 text-center">
              <div className="text-nx-fg2 text-xs tracking-widest uppercase">No containers</div>
              <div className="text-nx-fg2 text-[10px] mt-2">Create a container to get started.</div>
            </div>
          ) : (
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-nx-border text-[10px] text-nx-fg2 tracking-[0.2em] uppercase">
                  <th className="text-left px-5 py-3">Name</th>
                  <th className="text-left px-4 py-3">Status</th>
                  <th className="text-left px-4 py-3">Template</th>
                  <th className="text-left px-4 py-3">vCPU</th>
                  <th className="text-left px-4 py-3">Memory</th>
                  <th className="text-left px-4 py-3">IP</th>
                  <th className="text-right px-5 py-3">Operations</th>
                </tr>
              </thead>
              <tbody>
                {containers.map((ct) => (
                  <tr key={ct.id}
                    className="border-b border-nx-border/50 hover:bg-nx-dim/30 transition-colors cursor-pointer"
                    onClick={() => navigate(`/containers/${ct.id}`)}
                    onContextMenu={e => openContextMenu(e, ct)}
                  >
                    <td className="px-5 py-3.5 font-medium text-nx-fg font-mono tracking-wider">{ct.name}</td>
                    <td className="px-4 py-3.5"><StatusBadge status={ct.status} /></td>
                    <td className="px-4 py-3.5 text-nx-fg2 text-xs">{ct.template}</td>
                    <td className="px-4 py-3.5 text-nx-fg2 font-mono text-xs">{ct.vcpus}</td>
                    <td className="px-4 py-3.5 text-nx-fg2 font-mono text-xs">{(ct.memory_mb / 1024).toFixed(1)} GB</td>
                    <td className="px-4 py-3.5 text-nx-fg2 font-mono text-xs">{ct.ip ?? '—'}</td>
                    <td className="px-5 py-3.5" onClick={e => e.stopPropagation()}>
                      <div className="flex items-center justify-end gap-1">
                        {acting === ct.id ? <NxSpinner size={14} /> : (
                          <>
                            {stopped(ct) && (
                              <button title="Start" className="nx-btn-ghost p-1.5" onClick={() => action(ct.id, 'start')}>
                                <Play size={13} className="text-nx-green" />
                              </button>
                            )}
                            {running(ct) && (
                              <>
                                <button title="Stop" className="nx-btn-ghost p-1.5" onClick={() => action(ct.id, 'stop')}>
                                  <Square size={13} className="text-nx-red" />
                                </button>
                                <button title="Restart" className="nx-btn-ghost p-1.5" onClick={() => action(ct.id, 'restart')}>
                                  <RotateCcw size={13} />
                                </button>
                                <button title="Shell" className="nx-btn-ghost p-1.5" onClick={() => navigate(`/containers/${ct.id}/shell`)}>
                                  <Terminal size={13} className="text-nx-orange" />
                                </button>
                              </>
                            )}
                            <button title="Delete" className="nx-btn-ghost p-1.5" onClick={() => promptDelete(ct)}>
                              <Trash2 size={13} className="text-nx-red/70 hover:text-nx-red" />
                            </button>
                          </>
                        )}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>

      {/* Right-click context menu */}
      {contextMenu && (
        <div ref={menuRef} className="fixed z-50 w-48 bg-nx-surface border border-nx-border rounded-lg shadow-xl py-1 text-xs"
          style={{ left: contextMenu.x, top: contextMenu.y }}>
          <div className="px-3 py-2 border-b border-nx-border/50">
            <div className="font-mono text-nx-fg font-medium">{contextMenu.ct.name}</div>
            <StatusBadge status={contextMenu.ct.status} />
          </div>
          {stopped(contextMenu.ct) && (
            <CtxItem icon={<Play size={12} className="text-nx-green" />} label="Start"
              onClick={() => action(contextMenu.ct.id, 'start')} />
          )}
          {running(contextMenu.ct) && <>
            <CtxItem icon={<Square size={12} className="text-nx-red" />} label="Stop"
              onClick={() => action(contextMenu.ct.id, 'stop')} />
            <CtxItem icon={<RotateCcw size={12} />} label="Restart"
              onClick={() => action(contextMenu.ct.id, 'restart')} />
            <CtxItem icon={<Terminal size={12} className="text-nx-orange" />} label="Open Shell"
              onClick={() => { setContextMenu(null); navigate(`/containers/${contextMenu.ct.id}/shell`) }} />
          </>}
          {paused(contextMenu.ct) && (
            <CtxItem icon={<RefreshCw size={12} className="text-nx-orange" />} label="Unfreeze"
              onClick={() => action(contextMenu.ct.id, 'restart')} />
          )}
          <div className="border-t border-nx-border/30 mt-1 pt-1" />
          <CtxItem icon={<Trash2 size={12} className="text-nx-red" />} label="Delete"
            className="text-nx-red hover:bg-nx-red/10"
            onClick={() => promptDelete(contextMenu.ct)} />
        </div>
      )}

      {/* In-UI delete confirmation */}
      {deleteConfirm && (
        <NxModal title="Delete Container" onClose={() => setDeleteConfirm(null)} width="max-w-sm">
          <div className="space-y-4">
            <div className="flex items-start gap-3 p-3 rounded-lg bg-nx-red/5 border border-nx-red/20">
              <AlertTriangle size={16} className="text-nx-red shrink-0 mt-0.5" />
              <div className="text-xs text-nx-fg2">
                This will permanently destroy container <span className="text-nx-fg font-mono font-medium">{deleteConfirm.ct.name}</span> and all its data. This cannot be undone.
              </div>
            </div>
            <div>
              <label className="nx-label">
                Type <span className="text-nx-fg font-mono">{deleteConfirm.ct.name}</span> to confirm
              </label>
              <input
                className="nx-input"
                value={deleteInput}
                onChange={e => setDeleteInput(e.target.value)}
                placeholder={deleteConfirm.ct.name}
                autoFocus
                onKeyDown={e => { if (e.key === 'Enter' && deleteInput === deleteConfirm.ct.name) confirmDelete() }}
              />
            </div>
            <div className="flex justify-end gap-3">
              <button className="nx-btn-ghost" onClick={() => setDeleteConfirm(null)}>Cancel</button>
              <button
                className="nx-btn-danger flex items-center gap-2"
                disabled={deleteInput !== deleteConfirm.ct.name || deleting}
                onClick={confirmDelete}
              >
                {deleting && <NxSpinner size={13} />}
                <Trash2 size={13} /> Delete
              </button>
            </div>
          </div>
        </NxModal>
      )}

      {showCreate && (
        <NxModal title="Create Container" onClose={() => setShowCreate(false)} width="max-w-xl">
          <CreateContainerForm onSubmit={handleCreate} onCancel={() => setShowCreate(false)} />
        </NxModal>
      )}
    </AppLayout>
  )
}

function CtxItem({ icon, label, onClick, className = '' }: {
  icon: React.ReactNode; label: string; onClick: () => void; className?: string
}) {
  return (
    <button className={`w-full flex items-center gap-2.5 px-3 py-1.5 text-left text-nx-fg2 hover:bg-nx-dim hover:text-nx-fg transition-colors ${className}`}
      onClick={onClick}>
      {icon}<span className="tracking-wide">{label}</span>
    </button>
  )
}
