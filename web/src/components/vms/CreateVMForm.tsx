import { useState, useEffect } from 'react'
import { NxSpinner } from '../common/NxSpinner'
import { CreateVMPayload } from './types'
import { api } from '../../api/client'

interface Props {
  onSubmit: (payload: CreateVMPayload) => Promise<void>
  onCancel: () => void
}

export function CreateVMForm({ onSubmit, onCancel }: Props) {
  const [form, setForm] = useState<CreateVMPayload>({
    name: '',
    vcpus: 2,
    memory_mb: 2048,
    disk_gb: 20,
    os: 'linux',
    os_iso: '',
    network: 'default',
  })
  const [isos, setIsos] = useState<string[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    api.get<{ isos: string[] }>('/storage/isos').then(d => setIsos(d.isos)).catch(() => {})
  }, [])

  const set = (k: keyof CreateVMPayload, v: unknown) =>
    setForm(f => ({ ...f, [k]: v }))

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!form.name.trim()) { setError('Name is required'); return }
    setLoading(true)
    setError(null)
    try { await onSubmit(form) } catch (ex) {
      setError((ex as Error).message)
    } finally { setLoading(false) }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div className="grid grid-cols-2 gap-4">
        <div className="col-span-2">
          <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">Name</label>
          <input className="nx-input" placeholder="my-vm" value={form.name}
            onChange={e => set('name', e.target.value)} />
        </div>
        <div>
          <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">vCPUs</label>
          <input type="number" min={1} max={64} className="nx-input" value={form.vcpus}
            onChange={e => set('vcpus', +e.target.value)} />
        </div>
        <div>
          <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">Memory (MB)</label>
          <input type="number" min={256} step={256} className="nx-input" value={form.memory_mb}
            onChange={e => set('memory_mb', +e.target.value)} />
          <div className="text-xs text-nx-fg2 mt-0.5">{(form.memory_mb / 1024).toFixed(2)} GB</div>
        </div>
        <div>
          <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">Disk (GB)</label>
          <input type="number" min={1} className="nx-input" value={form.disk_gb}
            onChange={e => set('disk_gb', +e.target.value)} />
        </div>
        <div>
          <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">OS Type</label>
          <select className="nx-input" value={form.os} onChange={e => set('os', e.target.value)}>
            <option value="linux">Linux</option>
            <option value="windows">Windows</option>
            <option value="other">Other</option>
          </select>
        </div>
        <div className="col-span-2">
          <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">Boot ISO (optional)</label>
          <select className="nx-input" value={form.os_iso} onChange={e => set('os_iso', e.target.value)}>
            <option value="">— No ISO (blank disk) —</option>
            {isos.map(iso => <option key={iso} value={iso}>{iso}</option>)}
          </select>
        </div>
        <div className="col-span-2">
          <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">Network</label>
          <select className="nx-input" value={form.network} onChange={e => set('network', e.target.value)}>
            <option value="default">default (NAT)</option>
            <option value="bridge">bridge (direct)</option>
          </select>
        </div>
      </div>

      {error && <div className="text-nx-red text-xs">{error}</div>}

      <div className="flex justify-end gap-3 pt-2">
        <button type="button" className="nx-btn-ghost" onClick={onCancel}>Cancel</button>
        <button type="submit" className="nx-btn-primary flex items-center gap-2" disabled={loading}>
          {loading && <NxSpinner size={14} />}
          Create VM
        </button>
      </div>
    </form>
  )
}
