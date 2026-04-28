import { useState, useEffect } from 'react'
import { Plus, Play, Square, RotateCcw, Trash2, Terminal, Camera, Server } from 'lucide-react'
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

type ViewMode = 'all' | string  // 'all' or a node_id

export function VMList() {
  const [vms, setVms] = useState<ClusterVM[]>([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [acting, setActing] = useState<string | null>(null)
  const [viewMode, setViewMode] = useState<ViewMode>('all')
  const navigate = useNavigate()

  const fetchVMs = () => {
    setLoading(true)
    api.get<ClusterVM[]>('/cluster/vms')
      .then(setVms)
      .catch(() => api.get<VM[]>('/vms').then(data => setVms(data.map(v => ({ ...v, node_id: 'local', node_name: 'local' })))))
      .finally(() => setLoading(false))
  }

  useEffect(() => { fetchVMs() }, [])

  const nodes = [...new Map(vms.map(v => [v.node_id, v.node_name])).entries()]
  const displayed = viewMode === 'all' ? vms : vms.filter(v => v.node_id === viewMode)

  async function action(vm: ClusterVM, op: string) {
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
    if (!confirm(`Permanently deallocate instance "${vm.name}"? This operation is irreversible.`)) return
    setActing(vm.id)
    try {
      if (vm.node_id === 'local') {
        await api.delete(`/vms/${vm.id}`)
      }
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

  return (
    <AppLayout title="Virtual Instances">
      <div className="space-y-4">
        <div className="flex items-center justify-between gap-4 flex-wrap">
          {/* Node filter tabs */}
          <div className="flex items-center gap-1 flex-wrap">
            <button
              onClick={() => setViewMode('all')}
              className={`px-3 py-1 rounded text-[10px] tracking-widest uppercase transition-colors ${
                viewMode === 'all' ? 'bg-nx-orange/10 text-nx-orange border border-nx-orange/20' : 'text-nx-fg2 hover:text-nx-fg hover:bg-nx-dim'
              }`}
            >
              All Nodes ({vms.length})
            </button>
            {nodes.map(([nodeId, nodeName]) => (
              <button
                key={nodeId}
                onClick={() => setViewMode(nodeId)}
                className={`px-3 py-1 rounded text-[10px] tracking-widest uppercase transition-colors ${
                  viewMode === nodeId ? 'bg-nx-orange/10 text-nx-orange border border-nx-orange/20' : 'text-nx-fg2 hover:text-nx-fg hover:bg-nx-dim'
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
                    onClick={() => vm.node_id === 'local' ? navigate(`/vms/${vm.id}`) : undefined}
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
                    <td className="px-5 py-3.5" onClick={(e) => e.stopPropagation()}>
                      <div className="flex items-center justify-end gap-1">
                        {acting === vm.id ? (
                          <NxSpinner size={14} />
                        ) : (
                          <>
                            {vm.status === 'stopped' && (
                              <button title="Start" className="nx-btn-ghost p-1.5" onClick={() => action(vm, 'start')}>
                                <Play size={13} className="text-nx-green" />
                              </button>
                            )}
                            {vm.status === 'running' && (
                              <>
                                <button title="Stop" className="nx-btn-ghost p-1.5" onClick={() => action(vm, 'stop')}>
                                  <Square size={13} className="text-nx-red" />
                                </button>
                                <button title="Reboot" className="nx-btn-ghost p-1.5" onClick={() => action(vm, 'reboot')}>
                                  <RotateCcw size={13} />
                                </button>
                                {vm.node_id === 'local' && (
                                  <button title="Console" className="nx-btn-ghost p-1.5" onClick={() => navigate(`/vms/${vm.id}/console`)}>
                                    <Terminal size={13} className="text-nx-orange" />
                                  </button>
                                )}
                              </>
                            )}
                            {vm.node_id === 'local' && (
                              <>
                                <button title="Detail / Snapshots" className="nx-btn-ghost p-1.5" onClick={() => navigate(`/vms/${vm.id}`)}>
                                  <Camera size={13} />
                                </button>
                                <button title="Deallocate" className="nx-btn-ghost p-1.5" onClick={() => deleteVM(vm)}>
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

      {showCreate && (
        <NxModal title="Provision Virtual Instance" onClose={() => setShowCreate(false)} width="max-w-2xl">
          <CreateVMForm onSubmit={handleCreate} onCancel={() => setShowCreate(false)} />
        </NxModal>
      )}
    </AppLayout>
  )
}
