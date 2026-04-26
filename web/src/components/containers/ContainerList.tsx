import { useState, useEffect } from 'react'
import { Plus, Play, Square, RotateCcw, Trash2, Terminal } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { StatusBadge } from '../common/StatusBadge'
import { NxSpinner } from '../common/NxSpinner'
import { NxModal } from '../common/NxModal'
import { api } from '../../api/client'
import { Container, CreateContainerPayload } from './types'
import { CreateContainerForm } from './CreateContainerForm'
import { useNavigate } from 'react-router-dom'

export function ContainerList() {
  const [containers, setContainers] = useState<Container[]>([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [acting, setActing] = useState<string | null>(null)
  const navigate = useNavigate()

  const fetchContainers = () =>
    api.get<Container[]>('/containers').then(setContainers).finally(() => setLoading(false))

  useEffect(() => { fetchContainers() }, [])

  async function action(id: string, op: string) {
    setActing(id)
    try { await api.post(`/containers/${id}/${op}`) } finally { setActing(null); fetchContainers() }
  }

  async function deleteContainer(id: string, name: string) {
    if (!confirm(`Delete container "${name}"?`)) return
    setActing(id)
    try { await api.delete(`/containers/${id}`) } finally { setActing(null); fetchContainers() }
  }

  async function handleCreate(payload: CreateContainerPayload) {
    await api.post('/containers', payload)
    setShowCreate(false)
    fetchContainers()
  }

  return (
    <AppLayout title="Containers">
      <div className="space-y-4">
        <div className="flex items-center justify-between">
          <p className="text-xs text-nx-fg2">{containers.length} container{containers.length !== 1 ? 's' : ''}</p>
          <button className="nx-btn-primary flex items-center gap-2" onClick={() => setShowCreate(true)}>
            <Plus size={14} />
            Create Container
          </button>
        </div>

        <div className="nx-card overflow-hidden">
          {loading ? (
            <div className="flex items-center justify-center py-16"><NxSpinner size={24} /></div>
          ) : containers.length === 0 ? (
            <div className="py-16 text-center text-nx-fg2 text-sm">No containers. Create one to get started.</div>
          ) : (
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-nx-border text-xs text-nx-fg2 uppercase tracking-wider">
                  <th className="text-left px-5 py-3">Name</th>
                  <th className="text-left px-4 py-3">Status</th>
                  <th className="text-left px-4 py-3">Template</th>
                  <th className="text-left px-4 py-3">vCPU</th>
                  <th className="text-left px-4 py-3">Memory</th>
                  <th className="text-left px-4 py-3">IP</th>
                  <th className="text-right px-5 py-3">Actions</th>
                </tr>
              </thead>
              <tbody>
                {containers.map((ct) => (
                  <tr
                    key={ct.id}
                    className="border-b border-nx-border/50 hover:bg-nx-dim/30 transition-colors cursor-pointer"
                    onClick={() => navigate(`/containers/${ct.id}`)}
                  >
                    <td className="px-5 py-3.5 font-medium text-nx-fg">{ct.name}</td>
                    <td className="px-4 py-3.5"><StatusBadge status={ct.status} /></td>
                    <td className="px-4 py-3.5 text-nx-fg2 text-xs">{ct.template}</td>
                    <td className="px-4 py-3.5 text-nx-fg2 font-mono">{ct.vcpus}</td>
                    <td className="px-4 py-3.5 text-nx-fg2 font-mono">{(ct.memory_mb / 1024).toFixed(1)} GB</td>
                    <td className="px-4 py-3.5 text-nx-fg2 font-mono text-xs">{ct.ip ?? '—'}</td>
                    <td className="px-5 py-3.5" onClick={e => e.stopPropagation()}>
                      <div className="flex items-center justify-end gap-1">
                        {acting === ct.id ? <NxSpinner size={14} /> : (
                          <>
                            {ct.status === 'stopped' && (
                              <button title="Start" className="nx-btn-ghost p-1.5" onClick={() => action(ct.id, 'start')}>
                                <Play size={13} className="text-nx-green" />
                              </button>
                            )}
                            {ct.status === 'running' && (
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
                            <button title="Delete" className="nx-btn-ghost p-1.5" onClick={() => deleteContainer(ct.id, ct.name)}>
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

      {showCreate && (
        <NxModal title="Create Container" onClose={() => setShowCreate(false)} width="max-w-xl">
          <CreateContainerForm onSubmit={handleCreate} onCancel={() => setShowCreate(false)} />
        </NxModal>
      )}
    </AppLayout>
  )
}
