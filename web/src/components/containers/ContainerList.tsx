import { useState, useEffect, useRef, useCallback } from 'react'
import { Plus, Play, Square, RotateCcw, Trash2, Terminal } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { StatusBadge } from '../common/StatusBadge'
import { NxSpinner } from '../common/NxSpinner'
import { NxModal } from '../common/NxModal'
import { api } from '../../api/client'
import { Container, CreateContainerPayload } from './types'
import { CreateContainerForm } from './CreateContainerForm'
import { useNavigate } from 'react-router-dom'

interface ContextMenu {
  x: number
  y: number
  ct: Container
}

const MENU_W = 192
const MENU_H = 200

const CREATE_STEPS = [
  'Resolving template…',
  'Downloading rootfs…',
  'Extracting filesystem…',
  'Configuring container…',
  'Applying resource limits…',
  'Setting credentials…',
  'Finalising…',
]

export function ContainerList() {
  const [containers, setContainers] = useState<Container[]>([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [creating, setCreating] = useState(false)
  const [createStep, setCreateStep] = useState(0)
  const [acting, setActing] = useState<string | null>(null)
  const [contextMenu, setContextMenu] = useState<ContextMenu | null>(null)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const menuRef = useRef<HTMLDivElement>(null)
  const stepInterval = useRef<ReturnType<typeof setInterval> | null>(null)
  const navigate = useNavigate()

  const fetchContainers = useCallback(() =>
    api.get<Container[]>('/containers').then(setContainers).finally(() => setLoading(false)),
  [])

  useEffect(() => { fetchContainers() }, [fetchContainers])

  useEffect(() => {
    function onClickOutside(e: MouseEvent) {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setContextMenu(null)
      }
    }
    if (contextMenu) {
      document.addEventListener('mousedown', onClickOutside)
      return () => document.removeEventListener('mousedown', onClickOutside)
    }
  }, [contextMenu])

  const allSelected = containers.length > 0 && containers.every(c => selected.has(c.id))
  const someSelected = selected.size > 0

  function toggleSelectAll() {
    setSelected(allSelected ? new Set() : new Set(containers.map(c => c.id)))
  }

  function toggleSelect(id: string) {
    setSelected(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  async function action(id: string, op: string) {
    setContextMenu(null)
    setActing(id)
    try { await api.post(`/containers/${id}/${op}`) }
    finally { setActing(null); fetchContainers() }
  }

  async function bulkAction(op: string) {
    const targets = containers.filter(c => selected.has(c.id))
    setSelected(new Set())
    await Promise.all(targets.map(c => action(c.id, op).catch(() => {})))
  }

  async function removeContainer(id: string, name: string) {
    setContextMenu(null)
    if (!confirm(`Remove container "${name}"? This cannot be undone.`)) return
    setActing(id)
    try { await api.delete(`/containers/${id}`) }
    finally { setActing(null); fetchContainers() }
  }

  async function bulkRemove() {
    const targets = containers.filter(c => selected.has(c.id))
    if (!confirm(`Remove ${targets.length} container${targets.length > 1 ? 's' : ''}? This cannot be undone.`)) return
    setSelected(new Set())
    await Promise.all(targets.map(c => removeContainer(c.id, c.name).catch(() => {})))
  }

  async function handleCreate(payload: CreateContainerPayload) {
    setShowCreate(false)
    setCreating(true)
    setCreateStep(0)

    stepInterval.current = setInterval(() => {
      setCreateStep(s => Math.min(s + 1, CREATE_STEPS.length - 1))
    }, 2200)

    try {
      await api.post('/containers', payload)
    } finally {
      if (stepInterval.current) clearInterval(stepInterval.current)
      stepInterval.current = null
      setCreating(false)
      setCreateStep(0)
      fetchContainers()
    }
  }

  function openContextMenu(e: React.MouseEvent, ct: Container) {
    e.preventDefault()
    e.stopPropagation()
    const x = Math.min(e.clientX, window.innerWidth  - MENU_W - 4)
    const y = Math.min(e.clientY, window.innerHeight - MENU_H - 4)
    setContextMenu({ x: Math.max(x, 4), y: Math.max(y, 4), ct })
  }

  const running = (ct: Container) => ct.status === 'running'
  const stopped = (ct: Container) => ct.status === 'stopped'

  return (
    <AppLayout title="Containers">
      <div className="space-y-4">
        <div className="flex items-center justify-between gap-4 flex-wrap">
          <p className="text-xs text-nx-fg2 tracking-wider">
            {containers.length} container{containers.length !== 1 ? 's' : ''}
          </p>
          <div className="flex items-center gap-2">
            {someSelected && (
              <div className="flex items-center gap-1 px-3 py-1.5 bg-nx-bg2 rounded-xl border border-nx-border">
                <span className="text-[10px] text-nx-fg2 font-mono tracking-wider mr-1">
                  {selected.size} selected
                </span>
                <button
                  className="nx-btn-ghost px-2 py-1 text-[10px] tracking-wider flex items-center gap-1"
                  onClick={() => bulkAction('start')}
                  title="Start all selected"
                >
                  <Play size={10} className="text-nx-green" /> Start
                </button>
                <button
                  className="nx-btn-ghost px-2 py-1 text-[10px] tracking-wider flex items-center gap-1"
                  onClick={() => bulkAction('stop')}
                  title="Stop all selected"
                >
                  <Square size={10} className="text-nx-orange" /> Stop
                </button>
                <button
                  className="nx-btn-ghost px-2 py-1 text-[10px] tracking-wider flex items-center gap-1 text-nx-red hover:bg-nx-red/10"
                  onClick={bulkRemove}
                  title="Remove all selected"
                >
                  <Trash2 size={10} /> Remove
                </button>
                <button
                  className="nx-btn-ghost px-2 py-0.5 text-[10px] text-nx-fg2"
                  onClick={() => setSelected(new Set())}
                >✕</button>
              </div>
            )}
            <button className="nx-btn-primary flex items-center gap-2 text-xs tracking-wider"
              onClick={() => setShowCreate(true)}>
              <Plus size={13} />
              Create CT
            </button>
          </div>
        </div>

        {creating && (
          <div className="nx-card p-5">
            <div className="flex items-center gap-3 mb-3">
              <NxSpinner size={18} />
              <span className="text-xs text-nx-orange tracking-widest uppercase font-mono">
                Creating Container
              </span>
            </div>
            <div className="text-xs text-nx-fg2 mb-3 h-4 transition-all">
              {CREATE_STEPS[createStep]}
            </div>
            <div className="w-full h-1 bg-nx-dim rounded-full overflow-hidden">
              <div
                className="h-full bg-nx-orange rounded-full transition-all duration-700"
                style={{ width: `${((createStep + 1) / CREATE_STEPS.length) * 100}%` }}
              />
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
                  <th className="px-4 py-3 w-8">
                    <input
                      type="checkbox"
                      checked={allSelected}
                      onChange={toggleSelectAll}
                      className="accent-nx-orange cursor-pointer"
                    />
                  </th>
                  <th className="text-left px-3 py-3">Name</th>
                  <th className="text-left px-4 py-3">Status</th>
                  <th className="text-left px-4 py-3">Template</th>
                  <th className="text-left px-4 py-3">vCPU</th>
                  <th className="text-left px-4 py-3">Memory</th>
                  <th className="text-left px-4 py-3">IP Address</th>
                  <th className="text-right px-5 py-3">Actions</th>
                </tr>
              </thead>
              <tbody>
                {containers.map((ct) => {
                  const isSelected = selected.has(ct.id)
                  return (
                    <tr
                      key={ct.id}
                      className={`border-b border-nx-border/50 transition-colors cursor-pointer ${
                        isSelected ? 'bg-nx-orange/5' : 'hover:bg-nx-dim/30'
                      }`}
                      onClick={() => navigate(`/containers/${ct.id}`)}
                      onContextMenu={e => openContextMenu(e, ct)}
                    >
                      <td className="px-4 py-3.5" onClick={e => { e.stopPropagation(); toggleSelect(ct.id) }}>
                        <input
                          type="checkbox"
                          checked={isSelected}
                          readOnly
                          className="accent-nx-orange cursor-pointer"
                        />
                      </td>
                      <td className="px-3 py-3.5 font-medium text-nx-fg font-mono tracking-wider">{ct.name}</td>
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
                                <button title="Start" className="nx-btn-ghost p-1.5"
                                  onClick={() => action(ct.id, 'start')}>
                                  <Play size={13} className="text-nx-green" />
                                </button>
                              )}
                              {running(ct) && (
                                <>
                                  <button title="Stop" className="nx-btn-ghost p-1.5"
                                    onClick={() => action(ct.id, 'stop')}>
                                    <Square size={13} className="text-nx-orange" />
                                  </button>
                                  <button title="Restart" className="nx-btn-ghost p-1.5"
                                    onClick={() => action(ct.id, 'restart')}>
                                    <RotateCcw size={13} />
                                  </button>
                                  <button title="Console" className="nx-btn-ghost p-1.5"
                                    onClick={() => navigate(`/containers/${ct.id}/shell`)}>
                                    <Terminal size={13} className="text-nx-orange" />
                                  </button>
                                </>
                              )}
                              <button title="Remove" className="nx-btn-ghost p-1.5"
                                onClick={() => removeContainer(ct.id, ct.name)}>
                                <Trash2 size={13} className="text-nx-red/70 hover:text-nx-red" />
                              </button>
                            </>
                          )}
                        </div>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          )}
        </div>
      </div>

      {contextMenu && (
        <div
          ref={menuRef}
          className="fixed z-50 w-48 bg-nx-surface border border-nx-border rounded-lg shadow-xl py-1 text-xs"
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          <div className="px-3 py-2 border-b border-nx-border/50">
            <div className="font-mono text-nx-fg font-medium">{contextMenu.ct.name}</div>
            <StatusBadge status={contextMenu.ct.status} />
          </div>

          {stopped(contextMenu.ct) && (
            <CtMenuItem icon={<Play size={12} className="text-nx-green" />} label="Start"
              onClick={() => action(contextMenu.ct.id, 'start')} />
          )}
          {running(contextMenu.ct) && <>
            <CtMenuItem icon={<Square size={12} className="text-nx-orange" />} label="Stop"
              onClick={() => action(contextMenu.ct.id, 'stop')} />
            <CtMenuItem icon={<RotateCcw size={12} />} label="Restart"
              onClick={() => action(contextMenu.ct.id, 'restart')} />
            <CtMenuItem icon={<Terminal size={12} className="text-nx-orange" />} label="Console"
              onClick={() => { setContextMenu(null); navigate(`/containers/${contextMenu.ct.id}/shell`) }} />
          </>}

          <div className="border-t border-nx-border/30 mt-1 pt-1" />
          <CtMenuItem icon={<Trash2 size={12} className="text-nx-red" />} label="Remove"
            className="text-nx-red hover:bg-nx-red/10"
            onClick={() => removeContainer(contextMenu.ct.id, contextMenu.ct.name)} />
        </div>
      )}

      {showCreate && (
        <NxModal title="Create Container" onClose={() => setShowCreate(false)} width="max-w-xl">
          <CreateContainerForm onSubmit={handleCreate} onCancel={() => setShowCreate(false)} />
        </NxModal>
      )}
    </AppLayout>
  )
}

function CtMenuItem({
  icon, label, onClick, className = '',
}: {
  icon: React.ReactNode
  label: string
  onClick: () => void
  className?: string
}) {
  return (
    <button
      className={`w-full flex items-center gap-2.5 px-3 py-1.5 text-left text-nx-fg2 hover:bg-nx-dim hover:text-nx-fg transition-colors ${className}`}
      onClick={onClick}
    >
      {icon}
      <span className="tracking-wide">{label}</span>
    </button>
  )
}
