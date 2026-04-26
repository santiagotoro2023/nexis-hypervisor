import { useState, useEffect } from 'react'
import { Plus, Trash2, Network as NetIcon } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { NxSpinner } from '../common/NxSpinner'
import { NxModal } from '../common/NxModal'
import { api } from '../../api/client'

interface Bridge {
  name: string
  ip?: string
  mac?: string
  interfaces: string[]
  active: boolean
  forward_mode: string
}

export function Network() {
  const [bridges, setBridges] = useState<Bridge[]>([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [newName, setNewName] = useState('')
  const [creating, setCreating] = useState(false)

  const fetch = () =>
    api.get<Bridge[]>('/network/bridges').then(setBridges).finally(() => setLoading(false))

  useEffect(() => { fetch() }, [])

  async function createBridge() {
    if (!newName.trim()) return
    setCreating(true)
    try { await api.post('/network/bridges', { name: newName }) } finally {
      setCreating(false)
      setShowCreate(false)
      setNewName('')
      fetch()
    }
  }

  async function deleteBridge(name: string) {
    if (!confirm(`Delete bridge "${name}"?`)) return
    await api.delete(`/network/bridges/${name}`)
    fetch()
  }

  return (
    <AppLayout title="Network">
      <div className="space-y-4">
        <div className="flex items-center justify-between">
          <p className="text-xs text-nx-fg2">{bridges.length} bridge{bridges.length !== 1 ? 's' : ''}</p>
          <button className="nx-btn-primary flex items-center gap-2" onClick={() => setShowCreate(true)}>
            <Plus size={14} /> Create Bridge
          </button>
        </div>

        {loading ? (
          <div className="flex items-center justify-center py-20"><NxSpinner size={32} /></div>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {bridges.map(br => (
              <div key={br.name} className="nx-card p-5 space-y-3">
                <div className="flex items-start justify-between">
                  <div className="flex items-center gap-2">
                    <NetIcon size={16} className="text-nx-orange" />
                    <div>
                      <div className="font-medium text-nx-fg">{br.name}</div>
                      <div className="text-xs text-nx-fg2 font-mono mt-0.5">{br.ip ?? 'No IP'}</div>
                    </div>
                  </div>
                  <div className="flex items-center gap-2">
                    <span className={`text-xs px-2 py-0.5 rounded ${br.active ? 'bg-nx-green/10 text-nx-green' : 'bg-nx-border text-nx-fg2'}`}>
                      {br.forward_mode || 'isolated'}
                    </span>
                    {br.name !== 'default' && (
                      <button className="nx-btn-ghost p-1.5" onClick={() => deleteBridge(br.name)}>
                        <Trash2 size={13} className="text-nx-red/70 hover:text-nx-red" />
                      </button>
                    )}
                  </div>
                </div>
                {br.mac && <div className="text-xs text-nx-fg2 font-mono">MAC: {br.mac}</div>}
                {br.interfaces.length > 0 && (
                  <div className="text-xs text-nx-fg2">
                    Interfaces: {br.interfaces.join(', ')}
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>

      {showCreate && (
        <NxModal title="Create Bridge" onClose={() => setShowCreate(false)}>
          <div className="space-y-4">
            <div>
              <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">Bridge Name</label>
              <input className="nx-input" placeholder="virbr1" value={newName}
                onChange={e => setNewName(e.target.value)}
                onKeyDown={e => { if (e.key === 'Enter') createBridge() }}
              />
            </div>
            <div className="flex justify-end gap-3">
              <button className="nx-btn-ghost" onClick={() => setShowCreate(false)}>Cancel</button>
              <button className="nx-btn-primary flex items-center gap-2" onClick={createBridge} disabled={creating || !newName.trim()}>
                {creating && <NxSpinner size={14} />}
                Create
              </button>
            </div>
          </div>
        </NxModal>
      )}
    </AppLayout>
  )
}
