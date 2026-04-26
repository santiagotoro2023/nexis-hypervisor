import { useState, useEffect } from 'react'
import { NxSpinner } from '../common/NxSpinner'
import { CreateContainerPayload } from './types'
import { api } from '../../api/client'

interface Props {
  onSubmit: (p: CreateContainerPayload) => Promise<void>
  onCancel: () => void
}

export function CreateContainerForm({ onSubmit, onCancel }: Props) {
  const [form, setForm] = useState<CreateContainerPayload>({
    name: '',
    template: 'debian-12',
    vcpus: 1,
    memory_mb: 512,
    disk_gb: 8,
    password: '',
  })
  const [templates, setTemplates] = useState<string[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    api.get<{ templates: string[] }>('/containers/templates')
      .then(d => setTemplates(d.templates))
      .catch(() => setTemplates(['debian-12', 'ubuntu-22.04', 'alpine-3.18']))
  }, [])

  const set = (k: keyof CreateContainerPayload, v: unknown) =>
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
          <input className="nx-input" placeholder="my-container" value={form.name}
            onChange={e => set('name', e.target.value)} />
        </div>
        <div className="col-span-2">
          <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">Template</label>
          <select className="nx-input" value={form.template} onChange={e => set('template', e.target.value)}>
            {templates.map(t => <option key={t} value={t}>{t}</option>)}
          </select>
        </div>
        <div>
          <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">vCPUs</label>
          <input type="number" min={1} max={32} className="nx-input" value={form.vcpus}
            onChange={e => set('vcpus', +e.target.value)} />
        </div>
        <div>
          <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">Memory (MB)</label>
          <input type="number" min={64} step={64} className="nx-input" value={form.memory_mb}
            onChange={e => set('memory_mb', +e.target.value)} />
        </div>
        <div>
          <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">Disk (GB)</label>
          <input type="number" min={1} className="nx-input" value={form.disk_gb}
            onChange={e => set('disk_gb', +e.target.value)} />
        </div>
        <div>
          <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">Root Password</label>
          <input type="password" className="nx-input" placeholder="••••••••" value={form.password}
            onChange={e => set('password', e.target.value)} />
        </div>
      </div>

      {error && <div className="text-nx-red text-xs">{error}</div>}

      <div className="flex justify-end gap-3 pt-2">
        <button type="button" className="nx-btn-ghost" onClick={onCancel}>Cancel</button>
        <button type="submit" className="nx-btn-primary flex items-center gap-2" disabled={loading}>
          {loading && <NxSpinner size={14} />}
          Create Container
        </button>
      </div>
    </form>
  )
}
