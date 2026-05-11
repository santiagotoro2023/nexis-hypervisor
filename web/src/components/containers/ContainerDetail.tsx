import { useState, useEffect } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { Play, Square, RotateCcw, Trash2, Terminal, ChevronLeft, AlertTriangle } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { StatusBadge } from '../common/StatusBadge'
import { NxSpinner } from '../common/NxSpinner'
import { NxModal } from '../common/NxModal'
import { api } from '../../api/client'
import { Container } from './types'

export function ContainerDetail() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const [ct, setCt] = useState<Container | null>(null)
  const [acting, setActing] = useState<string | null>(null)
  const [deleteConfirm, setDeleteConfirm] = useState(false)
  const [deleteInput, setDeleteInput] = useState('')
  const [deleting, setDeleting] = useState(false)

  const fetch = () => {
    if (!id) return
    api.get<Container>(`/containers/${id}`).then(setCt).catch(() => navigate('/containers'))
  }

  useEffect(() => { fetch() }, [id])

  async function action(op: string) {
    if (!id) return
    setActing(op)
    try { await api.post(`/containers/${id}/${op}`) } finally { setActing(null); fetch() }
  }

  async function confirmDelete() {
    if (!id) return
    setDeleting(true)
    try {
      await api.delete(`/containers/${id}`)
      navigate('/containers')
    } finally {
      setDeleting(false)
    }
  }

  if (!ct) return (
    <AppLayout title="Container">
      <div className="flex items-center justify-center py-20"><NxSpinner size={32} /></div>
    </AppLayout>
  )

  const isRunning = ct.status === 'running'
  const isStopped = ct.status === 'stopped'

  return (
    <AppLayout title={ct.name}>
      <div className="space-y-5">
        <div className="flex items-center gap-3">
          <button onClick={() => navigate('/containers')} className="nx-btn-ghost flex items-center gap-1 text-xs">
            <ChevronLeft size={14} /> Containers
          </button>
          <StatusBadge status={ct.status} />
          <div className="ml-auto flex items-center gap-2">
            {acting ? <NxSpinner size={14} /> : (
              <>
                {isStopped && (
                  <button className="nx-btn-primary flex items-center gap-2" onClick={() => action('start')}>
                    <Play size={13} /> Start
                  </button>
                )}
                {isRunning && (
                  <>
                    <button className="nx-btn flex items-center gap-2 border border-nx-border text-nx-fg2 hover:text-nx-fg" onClick={() => action('restart')}>
                      <RotateCcw size={13} /> Restart
                    </button>
                    <button className="nx-btn-danger flex items-center gap-2" onClick={() => action('stop')}>
                      <Square size={13} /> Stop
                    </button>
                    <button className="nx-btn flex items-center gap-2 border border-nx-orange/30 text-nx-orange hover:bg-nx-orange/10"
                      onClick={() => navigate(`/containers/${id}/shell`)}>
                      <Terminal size={13} /> Shell
                    </button>
                  </>
                )}
              </>
            )}
          </div>
        </div>

        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
          {[
            { label: 'Template', value: ct.template },
            { label: 'vCPUs',    value: ct.vcpus },
            { label: 'Memory',   value: `${(ct.memory_mb / 1024).toFixed(1)} GB` },
            { label: 'IP',       value: ct.ip ?? '—' },
          ].map(({ label, value }) => (
            <div key={label} className="nx-card p-4">
              <div className="text-xs text-nx-fg2 uppercase tracking-wider">{label}</div>
              <div className="text-lg font-semibold text-nx-fg mt-1 font-mono">{String(value)}</div>
            </div>
          ))}
        </div>

        <div className="flex justify-end">
          <button
            className="nx-btn-danger flex items-center gap-2"
            onClick={() => { setDeleteInput(''); setDeleteConfirm(true) }}
          >
            <Trash2 size={13} /> Delete Container
          </button>
        </div>
      </div>

      {deleteConfirm && (
        <NxModal title="Delete Container" onClose={() => setDeleteConfirm(false)} width="max-w-sm">
          <div className="space-y-4">
            <div className="flex items-start gap-3 p-3 rounded-lg bg-nx-red/5 border border-nx-red/20">
              <AlertTriangle size={16} className="text-nx-red shrink-0 mt-0.5" />
              <div className="text-xs text-nx-fg2">
                This will permanently destroy container <span className="text-nx-fg font-mono font-medium">{ct.name}</span> and all its data. This cannot be undone.
              </div>
            </div>
            <div>
              <label className="nx-label">
                Type <span className="text-nx-fg font-mono">{ct.name}</span> to confirm
              </label>
              <input
                className="nx-input"
                value={deleteInput}
                onChange={e => setDeleteInput(e.target.value)}
                placeholder={ct.name}
                autoFocus
                onKeyDown={e => { if (e.key === 'Enter' && deleteInput === ct.name) confirmDelete() }}
              />
            </div>
            <div className="flex justify-end gap-3">
              <button className="nx-btn-ghost" onClick={() => setDeleteConfirm(false)}>Cancel</button>
              <button
                className="nx-btn-danger flex items-center gap-2"
                disabled={deleteInput !== ct.name || deleting}
                onClick={confirmDelete}
              >
                {deleting && <NxSpinner size={13} />}
                <Trash2 size={13} /> Delete
              </button>
            </div>
          </div>
        </NxModal>
      )}
    </AppLayout>
  )
}
