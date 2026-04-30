import { useState, useEffect, useRef, useCallback } from 'react'
import { Plus, Play, Square, RotateCcw, Trash2, Camera, Server,
         Pause, RefreshCw, Zap, Copy, Download, Monitor } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { StatusBadge } from '../common/StatusBadge'
import { NxSpinner } from '../common/NxSpinner'
import { NxModal } from '../common/NxModal'
import { api } from '../../api/client'
import { VM, CreateVMPayload } from './types'
import { CreateVMForm } from './CreateVMForm'
import { useNavigate } from 'react-router-dom'

interface ClusterVM extends VM {
  node_id: string
  node_name: string
}

interface ContextMenu {
  x: number
  y: number
  vm: ClusterVM
}

type ViewMode = 'all' | string

const MENU_W = 208
const MENU_H = 330

export function VMList() {
  const [vms, setVms] = useState<ClusterVM[]>([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [acting, setActing] = useState<string | null>(null)
  const [viewMode, setViewMode] = useState<ViewMode>('all')
  const [contextMenu, setContextMenu] = useState<ContextMenu | null>(null)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const menuRef = useRef<HTMLDivElement>(null)
  const navigate = useNavigate()

  const vmKey = (vm: ClusterVM) => `${vm.node_id}:${vm.id}`

  const fetchVMs = useCallback(() => {
    setLoading(true)
    api.get<ClusterVM[]>('/cluster/vms')
      .then(setVms)
      .catch(() => api.get<VM[]>('/vms').then(data =>
        setVms(data.map(v => ({ ...v, node_id: 'local', node_name: 'local' })))
      ))
      .finally(() => setLoading(false))
  }, [])

  useEffect(() => { fetchVMs() }, [fetchVMs])

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

  const nodes = [...new Map(vms.map(v => [v.node_id, v.node_name])).entries()]
  const displayed = viewMode === 'all' ? vms : vms.filter(v => v.node_id === viewMode)

  const allSelected = displayed.length > 0 && displayed.every(v => selected.has(vmKey(v)))
  const someSelected = selected.size > 0

  function toggleSelectAll() {
    setSelected(allSelected ? new Set() : new Set(displayed.map(vmKey)))
  }

  function toggleSelect(vm: ClusterVM) {
    setSelected(prev => {
      const next = new Set(prev)
      const key = vmKey(vm)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

  async function action(vm: ClusterVM, op: string) {
    setContextMenu(null)
    setActing(vm.id)
    try {
      if (vm.node_id === 'local') {
        await api.post(`/vms/${vm.id}/${op}`)
      } else {
        await api.post(`/cluster/nodes/${vm.node_id}/vms/${vm.id}/${op}`)
      }
    } finally {
      setActing(null)
      fetchVMs()
    }
  }

  async function bulkAction(op: string) {
    const targets = displayed.filter(v => selected.has(vmKey(v)))
    setSelected(new Set())
    await Promise.all(targets.map(v => action(v, op).catch(() => {})))
  }

  async function removeVM(vm: ClusterVM) {
    setContextMenu(null)
    if (!confirm(`Remove VM "${vm.name}"? This cannot be undone.`)) return
    setActing(vm.id)
    try {
      if (vm.node_id === 'local') await api.delete(`/vms/${vm.id}`)
    } finally {
      setActing(null)
      fetchVMs()
    }
  }

  async function bulkRemove() {
    const targets = displayed.filter(v => selected.has(vmKey(v)))
    if (!confirm(`Remove ${targets.length} VM${targets.length > 1 ? 's' : ''}? This cannot be undone.`)) return
    setSelected(new Set())
    await Promise.all(targets.map(v => removeVM(v).catch(() => {})))
  }

  async function handleCreate(payload: CreateVMPayload) {
    await api.post('/vms', payload)
    setShowCreate(false)
    fetchVMs()
  }

  function openContextMenu(e: React.MouseEvent, vm: ClusterVM) {
    e.preventDefault()
    e.stopPropagation()
    const x = Math.min(e.clientX, window.innerWidth  - MENU_W - 4)
    const y = Math.min(e.clientY, window.innerHeight - MENU_H - 4)
    setContextMenu({ x: Math.max(x, 4), y: Math.max(y, 4), vm })
  }

  const canStart = (vm: ClusterVM) => ['stopped', 'crashed', 'unknown'].includes(vm.status)
  const running  = (vm: ClusterVM) => vm.status === 'running'
  const paused   = (vm: ClusterVM) => vm.status === 'paused'
  const local    = (vm: ClusterVM) => vm.node_id === 'local'

  return (
    <AppLayout title="Virtual Machines">
      <div className="space-y-4">
        <div className="flex items-center justify-between gap-4 flex-wrap">
          <div className="flex items-center gap-1 flex-wrap">
            <button
              onClick={() => setViewMode('all')}
              className={`px-3 py-1 rounded text-[10px] tracking-widest uppercase transition-colors ${
                viewMode === 'all'
                  ? 'bg-nx-orange/10 text-nx-orange border border-nx-orange/20'
                  : 'text-nx-fg2 hover:text-nx-fg hover:bg-nx-dim'
              }`}
            >
              All Nodes ({vms.length})
            </button>
            {nodes.map(([nodeId, nodeName]) => (
              <button
                key={nodeId}
                onClick={() => setViewMode(nodeId)}
                className={`px-3 py-1 rounded text-[10px] tracking-widest uppercase transition-colors ${
                  viewMode === nodeId
                    ? 'bg-nx-orange/10 text-nx-orange border border-nx-orange/20'
                    : 'text-nx-fg2 hover:text-nx-fg hover:bg-nx-dim'
                }`}
              >
                {nodeName} ({vms.filter(v => v.node_id === nodeId).length})
              </button>
            ))}
          </div>
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
                  title="Shutdown all selected"
                >
                  <Square size={10} className="text-nx-orange" /> Shutdown
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
            <button
              className="nx-btn-primary flex items-center gap-2 text-xs tracking-wider"
              onClick={() => setShowCreate(true)}
            >
              <Plus size={13} />
              Create VM
            </button>
          </div>
        </div>

        <div className="nx-card overflow-hidden">
          {loading ? (
            <div className="flex items-center justify-center py-16 text-nx-fg2">
              <NxSpinner size={24} />
            </div>
          ) : displayed.length === 0 ? (
            <div className="py-16 text-center">
              <div className="text-nx-fg2 text-xs tracking-widest uppercase">No virtual machines</div>
              <div className="text-nx-fg2 text-[10px] mt-2">Create a VM to get started.</div>
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
                  <th className="text-left px-4 py-3">Node</th>
                  <th className="text-left px-4 py-3">vCPU</th>
                  <th className="text-left px-4 py-3">Memory</th>
                  <th className="text-left px-4 py-3">Disk</th>
                  <th className="text-left px-4 py-3">IP Address</th>
                  <th className="text-right px-5 py-3">Actions</th>
                </tr>
              </thead>
              <tbody>
                {displayed.map((vm) => {
                  const key = vmKey(vm)
                  const isSelected = selected.has(key)
                  return (
                    <tr
                      key={key}
                      className={`border-b border-nx-border/50 transition-colors cursor-pointer ${
                        isSelected ? 'bg-nx-orange/5' : 'hover:bg-nx-dim/30'
                      }`}
                      onClick={() => local(vm) ? navigate(`/vms/${vm.id}`) : undefined}
                      onContextMenu={e => openContextMenu(e, vm)}
                    >
                      <td className="px-4 py-3.5" onClick={e => { e.stopPropagation(); toggleSelect(vm) }}>
                        <input
                          type="checkbox"
                          checked={isSelected}
                          readOnly
                          className="accent-nx-orange cursor-pointer"
                        />
                      </td>
                      <td className="px-3 py-3.5">
                        <div className="font-medium text-nx-fg font-mono tracking-wider">{vm.name}</div>
                        <div className="text-[10px] text-nx-fg2 tracking-wider uppercase mt-0.5">{vm.os}</div>
                      </td>
                      <td className="px-4 py-3.5"><StatusBadge status={vm.status} /></td>
                      <td className="px-4 py-3.5">
                        <div className="flex items-center gap-1.5">
                          <Server size={11} className="text-nx-fg2" />
                          <span className="text-nx-fg2 text-xs font-mono">{vm.node_name}</span>
                        </div>
                      </td>
                      <td className="px-4 py-3.5 text-nx-fg2 font-mono text-xs">{vm.vcpus}</td>
                      <td className="px-4 py-3.5 text-nx-fg2 font-mono text-xs">{(vm.memory_mb / 1024).toFixed(1)} GB</td>
                      <td className="px-4 py-3.5 text-nx-fg2 font-mono text-xs">{vm.disk_gb} GB</td>
                      <td className="px-4 py-3.5 text-nx-fg2 font-mono text-xs">{vm.ip ?? '—'}</td>
                      <td className="px-5 py-3.5" onClick={e => e.stopPropagation()}>
                        <div className="flex items-center justify-end gap-1">
                          {acting === vm.id ? (
                            <NxSpinner size={14} />
                          ) : (
                            <>
                              {canStart(vm) && (
                                <button title="Start" className="nx-btn-ghost p-1.5" onClick={() => action(vm, 'start')}>
                                  <Play size={13} className="text-nx-green" />
                                </button>
                              )}
                              {(running(vm) || paused(vm)) && (
                                <button title="Shutdown" className="nx-btn-ghost p-1.5" onClick={() => action(vm, 'stop')}>
                                  <Square size={13} className="text-nx-orange" />
                                </button>
                              )}
                              {running(vm) && (
                                <>
                                  <button title="Suspend" className="nx-btn-ghost p-1.5" onClick={() => action(vm, 'suspend')}>
                                    <Pause size={13} className="text-nx-orange/70" />
                                  </button>
                                  <button title="Reboot" className="nx-btn-ghost p-1.5" onClick={() => action(vm, 'reboot')}>
                                    <RotateCcw size={13} />
                                  </button>
                                </>
                              )}
                              {paused(vm) && (
                                <button title="Resume" className="nx-btn-ghost p-1.5" onClick={() => action(vm, 'resume')}>
                                  <Play size={13} className="text-nx-orange" />
                                </button>
                              )}
                              {local(vm) && running(vm) && (
                                <button title="Console" className="nx-btn-ghost p-1.5"
                                  onClick={() => navigate(`/vms/${vm.id}/console`)}>
                                  <Monitor size={13} className="text-nx-orange" />
                                </button>
                              )}
                              {local(vm) && (
                                <>
                                  <button title="Snapshots" className="nx-btn-ghost p-1.5"
                                    onClick={() => navigate(`/vms/${vm.id}`)}>
                                    <Camera size={13} />
                                  </button>
                                  <button title="Remove" className="nx-btn-ghost p-1.5"
                                    onClick={() => removeVM(vm)}>
                                    <Trash2 size={13} className="text-nx-red/70 hover:text-nx-red" />
                                  </button>
                                </>
                              )}
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
          className="fixed z-50 w-52 bg-nx-surface border border-nx-border rounded-lg shadow-xl py-1 text-xs"
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          <div className="px-3 py-2 border-b border-nx-border/50">
            <div className="font-mono text-nx-fg font-medium">{contextMenu.vm.name}</div>
            <StatusBadge status={contextMenu.vm.status} />
          </div>

          {canStart(contextMenu.vm) && (
            <MenuItem icon={<Play size={12} className="text-nx-green" />} label="Start"
              onClick={() => action(contextMenu.vm, 'start')} />
          )}
          {running(contextMenu.vm) && <>
            <MenuItem icon={<Square size={12} className="text-nx-orange" />} label="Shutdown"
              onClick={() => action(contextMenu.vm, 'stop')} />
            <MenuItem icon={<Zap size={12} className="text-nx-red" />} label="Stop (Force)"
              onClick={() => action(contextMenu.vm, 'force-stop')} />
            <MenuItem icon={<Pause size={12} className="text-nx-orange/80" />} label="Suspend"
              onClick={() => action(contextMenu.vm, 'suspend')} />
            <MenuItem icon={<RefreshCw size={12} />} label="Reset"
              onClick={() => action(contextMenu.vm, 'reset')} />
            <MenuItem icon={<RotateCcw size={12} />} label="Reboot"
              onClick={() => action(contextMenu.vm, 'reboot')} />
          </>}
          {paused(contextMenu.vm) && (
            <MenuItem icon={<Play size={12} className="text-nx-orange" />} label="Resume"
              onClick={() => action(contextMenu.vm, 'resume')} />
          )}

          {local(contextMenu.vm) && <>
            <div className="border-t border-nx-border/30 mt-1 pt-1" />
            {running(contextMenu.vm) && (
              <MenuItem icon={<Monitor size={12} className="text-nx-orange" />} label="Console"
                onClick={() => { setContextMenu(null); navigate(`/vms/${contextMenu.vm.id}/console`) }} />
            )}
            <MenuItem icon={<Camera size={12} />} label="Snapshots"
              onClick={() => { setContextMenu(null); navigate(`/vms/${contextMenu.vm.id}`) }} />
            <MenuItem icon={<Copy size={12} />} label="Clone"
              onClick={() => {
                const n = prompt('Clone name:')
                if (n) { setContextMenu(null); api.post(`/vms/${contextMenu.vm.id}/clone`, { name: n }).then(fetchVMs) }
              }} />
            <MenuItem icon={<Download size={12} />} label="Backup"
              onClick={() => { api.post(`/vms/${contextMenu.vm.id}/backup`); setContextMenu(null) }} />
            <div className="border-t border-nx-border/30 mt-1 pt-1" />
            <MenuItem icon={<Trash2 size={12} className="text-nx-red" />} label="Remove"
              className="text-nx-red hover:bg-nx-red/10"
              onClick={() => removeVM(contextMenu.vm)} />
          </>}
        </div>
      )}

      {showCreate && (
        <NxModal title="Create Virtual Machine" onClose={() => setShowCreate(false)} width="max-w-2xl">
          <CreateVMForm onSubmit={handleCreate} onCancel={() => setShowCreate(false)} />
        </NxModal>
      )}
    </AppLayout>
  )
}

function MenuItem({
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
