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

export function VMList() {
  const [vms, setVms] = useState<ClusterVM[]>([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [acting, setActing] = useState<string | null>(null)
  const [viewMode, setViewMode] = useState<ViewMode>('all')
  const [contextMenu, setContextMenu] = useState<ContextMenu | null>(null)
  const menuRef = useRef<HTMLDivElement>(null)
  const navigate = useNavigate()

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

  async function deleteVM(vm: ClusterVM) {
    setContextMenu(null)
    if (!confirm(`Permanently deallocate instance "${vm.name}"? This operation is irreversible.`)) return
    setActing(vm.id)
    try {
      if (vm.node_id === 'local') await api.delete(`/vms/${vm.id}`)
    } finally {
      setActing(null)
      fetchVMs()
    }
  }

  async function handleCreate(payload: CreateVMPayload) {
    await api.post('/vms', payload)
    setShowCreate(false)
    fetchVMs()
  }

  function openContextMenu(e: React.MouseEvent, vm: ClusterVM) {
    e.preventDefault()
    e.stopPropagation()
    setContextMenu({ x: e.clientX, y: e.clientY, vm })
  }

  const running = (vm: ClusterVM) => vm.status === 'running'
  const stopped = (vm: ClusterVM) => vm.status === 'stopped'
  const paused  = (vm: ClusterVM) => vm.status === 'paused'
  const local   = (vm: ClusterVM) => vm.node_id === 'local'

  return (
    <AppLayout title="Virtual Instances">
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
          <button
            className="nx-btn-primary flex items-center gap-2 text-xs tracking-wider"
            onClick={() => setShowCreate(true)}
          >
            <Plus size={13} />
            Provision Instance
          </button>
        </div>

        <div className="nx-card overflow-hidden">
          {loading ? (
            <div className="flex items-center justify-center py-16 text-nx-fg2">
              <NxSpinner size={24} />
            </div>
          ) : displayed.length === 0 ? (
            <div className="py-16 text-center">
              <div className="text-nx-fg2 text-xs tracking-widest uppercase">No instances provisioned</div>
              <div className="text-nx-fg2 text-[10px] mt-2">Provision a virtual instance to begin operations.</div>
            </div>
          ) : (
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-nx-border text-[10px] text-nx-fg2 tracking-[0.2em] uppercase">
                  <th className="text-left px-5 py-3">Instance</th>
                  <th className="text-left px-4 py-3">State</th>
                  <th className="text-left px-4 py-3">Node</th>
                  <th className="text-left px-4 py-3">vCPU</th>
                  <th className="text-left px-4 py-3">Memory</th>
                  <th className="text-left px-4 py-3">Disk</th>
                  <th className="text-left px-4 py-3">Address</th>
                  <th className="text-right px-5 py-3">Operations</th>
                </tr>
              </thead>
              <tbody>
                {displayed.map((vm) => (
                  <tr
                    key={`${vm.node_id}:${vm.id}`}
                    className="border-b border-nx-border/50 hover:bg-nx-dim/30 transition-colors cursor-pointer"
                    onClick={() => local(vm) ? navigate(`/vms/${vm.id}`) : undefined}
                    onContextMenu={e => openContextMenu(e, vm)}
                  >
                    <td className="px-5 py-3.5">
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
                            {stopped(vm) && (
                              <button title="Start" className="nx-btn-ghost p-1.5" onClick={() => action(vm, 'start')}>
                                <Play size={13} className="text-nx-green" />
                              </button>
                            )}
                            {(running(vm) || paused(vm)) && (
                              <button title="Stop" className="nx-btn-ghost p-1.5" onClick={() => action(vm, 'stop')}>
                                <Square size={13} className="text-nx-red" />
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
                                <button title="Snapshots / Detail" className="nx-btn-ghost p-1.5"
                                  onClick={() => navigate(`/vms/${vm.id}`)}>
                                  <Camera size={13} />
                                </button>
                                <button title="Deallocate" className="nx-btn-ghost p-1.5"
                                  onClick={() => deleteVM(vm)}>
                                  <Trash2 size={13} className="text-nx-red/70 hover:text-nx-red" />
                                </button>
                              </>
                            )}
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
        <div
          ref={menuRef}
          className="fixed z-50 w-52 bg-nx-surface border border-nx-border rounded-lg shadow-xl py-1 text-xs"
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          <div className="px-3 py-2 border-b border-nx-border/50">
            <div className="font-mono text-nx-fg font-medium">{contextMenu.vm.name}</div>
            <StatusBadge status={contextMenu.vm.status} />
          </div>

          {stopped(contextMenu.vm) && (
            <MenuItem icon={<Play size={12} className="text-nx-green" />} label="Start"
              onClick={() => action(contextMenu.vm, 'start')} />
          )}
          {running(contextMenu.vm) && <>
            <MenuItem icon={<Square size={12} className="text-nx-red" />} label="Graceful Stop"
              onClick={() => action(contextMenu.vm, 'stop')} />
            <MenuItem icon={<Zap size={12} className="text-nx-red" />} label="Force Stop"
              onClick={() => action(contextMenu.vm, 'force-stop')} />
            <MenuItem icon={<Pause size={12} className="text-nx-orange" />} label="Suspend"
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
              <MenuItem icon={<Monitor size={12} className="text-nx-orange" />} label="Open Console"
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
            <MenuItem icon={<Trash2 size={12} className="text-nx-red" />} label="Deallocate"
              className="text-nx-red hover:bg-nx-red/10"
              onClick={() => deleteVM(contextMenu.vm)} />
          </>}
        </div>
      )}

      {showCreate && (
        <NxModal title="Provision Virtual Instance" onClose={() => setShowCreate(false)} width="max-w-2xl">
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
