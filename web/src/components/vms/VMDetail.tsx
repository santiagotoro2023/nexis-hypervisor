import { useState, useEffect } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { Play, Square, RotateCcw, Zap, Camera, ChevronLeft, Trash2, Terminal } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { StatusBadge } from '../common/StatusBadge'
import { NxSpinner } from '../common/NxSpinner'
import { NxGauge } from '../common/NxGauge'
import { api } from '../../api/client'
import { VM, VMSnapshot } from './types'

export function VMDetail() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const [vm, setVm] = useState<VM | null>(null)
  const [snapshots, setSnapshots] = useState<VMSnapshot[]>([])
  const [acting, setActing] = useState<string | null>(null)
  const [snapName, setSnapName] = useState('')

  const fetch = () => {
    if (!id) return
    api.get<VM>(`/vms/${id}`).then(setVm)
    api.get<VMSnapshot[]>(`/vms/${id}/snapshots`).then(setSnapshots)
  }

  useEffect(() => { fetch() }, [id])

  async function action(op: string) {
    if (!id) return
    setActing(op)
    try { await api.post(`/vms/${id}/${op}`) } finally { setActing(null); fetch() }
  }

  async function createSnap() {
    if (!id || !snapName.trim()) return
    setActing('snap')
    try { await api.post(`/vms/${id}/snapshots`, { name: snapName }) } finally {
      setActing(null); setSnapName(''); fetch()
    }
  }

  async function restoreSnap(name: string) {
    if (!id || !confirm(`Restore snapshot "${name}"?`)) return
    setActing('restore')
    try { await api.post(`/vms/${id}/snapshots/${name}/restore`) } finally { setActing(null); fetch() }
  }

  async function deleteSnap(name: string) {
    if (!id || !confirm(`Delete snapshot "${name}"?`)) return
    setActing('delsnap')
    try { await api.delete(`/vms/${id}/snapshots/${name}`) } finally { setActing(null); fetch() }
  }

  if (!vm) return (
    <AppLayout title="Virtual Machine">
      <div className="flex items-center justify-center py-20"><NxSpinner size={32} /></div>
    </AppLayout>
  )

  return (
    <AppLayout title={vm.name}>
      <div className="space-y-5">
        <div className="flex items-center gap-3">
          <button onClick={() => navigate('/vms')} className="nx-btn-ghost flex items-center gap-1 text-xs">
            <ChevronLeft size={14} /> VMs
          </button>
          <StatusBadge status={vm.status} />
          <div className="ml-auto flex items-center gap-2">
            {acting ? <NxSpinner size={14} /> : (
              <>
                {vm.status === 'stopped' && (
                  <button className="nx-btn-primary flex items-center gap-2" onClick={() => action('start')}>
                    <Play size={13} /> Start
                  </button>
                )}
                {vm.status === 'running' && (
                  <>
                    <button className="nx-btn flex items-center gap-2 border border-nx-border text-nx-fg2 hover:text-nx-fg" onClick={() => action('reboot')}>
                      <RotateCcw size={13} /> Reboot
                    </button>
                    <button className="nx-btn-danger flex items-center gap-2" onClick={() => action('stop')}>
                      <Square size={13} /> Stop
                    </button>
                    <button className="nx-btn flex items-center gap-2 border border-nx-orange/30 text-nx-orange hover:bg-nx-orange/10" onClick={() => navigate(`/vms/${id}/console`)}>
                      <Terminal size={13} /> Console
                    </button>
                  </>
                )}
                {vm.status === 'running' && (
                  <button className="nx-btn-danger flex items-center gap-2" onClick={() => action('force-stop')}>
                    <Zap size={13} /> Force Stop
                  </button>
                )}
              </>
            )}
          </div>
        </div>

        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
          {[
            { label: 'vCPUs', value: vm.vcpus },
            { label: 'Memory', value: `${(vm.memory_mb / 1024).toFixed(1)} GB` },
            { label: 'Disk', value: `${vm.disk_gb} GB` },
            { label: 'IP', value: vm.ip ?? '—' },
          ].map(({ label, value }) => (
            <div key={label} className="nx-card p-4">
              <div className="text-xs text-nx-fg2 uppercase tracking-wider">{label}</div>
              <div className="text-lg font-semibold text-nx-fg mt-1 font-mono">{value}</div>
            </div>
          ))}
        </div>

        {vm.status === 'running' && (
          <div className="grid grid-cols-2 gap-4">
            <div className="nx-card p-5">
              <NxGauge label="CPU" value={vm.cpu_percent ?? 0} unit="%" percent={vm.cpu_percent ?? 0} />
            </div>
            <div className="nx-card p-5">
              <NxGauge label="Memory" value={vm.memory_percent ?? 0} unit="%" percent={vm.memory_percent ?? 0} />
            </div>
          </div>
        )}

        {/* Snapshots */}
        <div className="nx-card">
          <div className="flex items-center justify-between px-5 py-3 border-b border-nx-border">
            <h3 className="text-xs text-nx-fg2 uppercase tracking-wider flex items-center gap-2">
              <Camera size={13} /> Snapshots
            </h3>
            <div className="flex items-center gap-2">
              <input
                className="nx-input w-48 text-xs py-1"
                placeholder="Snapshot name"
                value={snapName}
                onChange={e => setSnapName(e.target.value)}
              />
              <button className="nx-btn-primary text-xs py-1" onClick={createSnap} disabled={!snapName.trim() || !!acting}>
                {acting === 'snap' ? <NxSpinner size={12} /> : 'Take'}
              </button>
            </div>
          </div>
          {snapshots.length === 0 ? (
            <div className="py-8 text-center text-nx-fg2 text-xs">No snapshots</div>
          ) : (
            <div className="divide-y divide-nx-border/50">
              {snapshots.map(s => (
                <div key={s.name} className="flex items-center justify-between px-5 py-3">
                  <div>
                    <div className="text-sm text-nx-fg">{s.name}</div>
                    <div className="text-xs text-nx-fg2">{new Date(s.created).toLocaleString()}</div>
                  </div>
                  <div className="flex items-center gap-2">
                    <button className="nx-btn-ghost text-xs py-1" onClick={() => restoreSnap(s.name)}>Restore</button>
                    <button className="nx-btn-ghost p-1.5" onClick={() => deleteSnap(s.name)}>
                      <Trash2 size={13} className="text-nx-red/70 hover:text-nx-red" />
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        <div className="flex justify-end">
          <button
            className="nx-btn-danger flex items-center gap-2"
            onClick={async () => {
              if (!confirm(`Permanently delete VM "${vm.name}"?`)) return
              await api.delete(`/vms/${id}`)
              navigate('/vms')
            }}
          >
            <Trash2 size={13} /> Delete VM
          </button>
        </div>
      </div>
    </AppLayout>
  )
}
