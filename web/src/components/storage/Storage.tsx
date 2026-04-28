import { useState, useEffect, useRef } from 'react'
import { Upload, Trash2, HardDrive, FolderOpen, Download, Plus, X, Globe, CheckCircle, AlertCircle } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { NxSpinner } from '../common/NxSpinner'
import { NxGauge } from '../common/NxGauge'
import { NxModal } from '../common/NxModal'
import { api } from '../../api/client'

interface Pool {
  id: string
  name: string
  path: string
  capacity_gb: number
  used_gb: number
  available_gb: number
  type: string
  active: boolean
  builtin?: boolean
}

interface ISOFile {
  name: string
  size_mb: number
  path: string
}

interface CatalogItem {
  id: string
  name: string
  version: string
  category: string
  size_gb: number
  url: string
  filename: string
  note?: string
  downloaded: boolean
}

type DownloadState = { progress: number; downloaded_mb: number; total_mb: number } | { done: boolean; name: string } | { error: string } | null

export function Storage() {
  const [pools, setPools] = useState<Pool[]>([])
  const [isos, setIsos] = useState<ISOFile[]>([])
  const [catalog, setCatalog] = useState<CatalogItem[]>([])
  const [loading, setLoading] = useState(true)
  const [uploading, setUploading] = useState(false)
  const [showAddPool, setShowAddPool] = useState(false)
  const [showCatalog, setShowCatalog] = useState(false)
  const [downloading, setDownloading] = useState<Record<string, DownloadState>>({})
  const fileRef = useRef<HTMLInputElement>(null)

  const fetch = () =>
    Promise.all([
      api.get<Pool[]>('/storage/pools').then(setPools),
      api.get<ISOFile[]>('/storage/isos/list').then(setIsos),
      api.get<CatalogItem[]>('/storage/catalog').then(setCatalog),
    ]).finally(() => setLoading(false))

  useEffect(() => { fetch() }, [])

  async function uploadISO(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    setUploading(true)
    const form = new FormData()
    form.append('file', file)
    try { await api.postForm('/storage/isos/upload', form) } finally {
      setUploading(false)
      fetch()
    }
  }

  async function deleteISO(name: string) {
    if (!confirm(`Delete ISO "${name}"?`)) return
    await api.delete(`/storage/isos/${encodeURIComponent(name)}`)
    fetch()
  }

  async function removePool(id: string) {
    if (!confirm('Remove this storage pool?')) return
    await api.delete(`/storage/pools/${id}`)
    fetch()
  }

  async function downloadFromCatalog(item: CatalogItem) {
    if (!item.url) return
    const key = item.id
    setDownloading(d => ({ ...d, [key]: { progress: 0, downloaded_mb: 0, total_mb: item.size_gb * 1024 } }))

    const token = sessionStorage.getItem('nx_token')
    try {
      const res = await window.fetch('/api/storage/isos/fetch', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify({ url: item.url, filename: item.filename }),
      })

      const reader = res.body!.getReader()
      const decoder = new TextDecoder()
      let buf = ''

      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buf += decoder.decode(value, { stream: true })
        const parts = buf.split('\n\n')
        buf = parts.pop() ?? ''
        for (const part of parts) {
          for (const line of part.split('\n')) {
            if (!line.startsWith('data: ')) continue
            try {
              const ev = JSON.parse(line.slice(6))
              setDownloading(d => ({ ...d, [key]: ev }))
            } catch { /* skip */ }
          }
        }
      }
    } catch (e) {
      setDownloading(d => ({ ...d, [key]: { error: (e as Error).message } }))
    }

    setTimeout(() => {
      setDownloading(d => { const n = { ...d }; delete n[key]; return n })
      fetch()
    }, 3000)
  }

  const categories = [...new Set(catalog.map(c => c.category))]

  return (
    <AppLayout title="Storage">
      <div className="space-y-6">
        {loading ? (
          <div className="flex items-center justify-center py-20"><NxSpinner size={32} /></div>
        ) : (
          <>
            {/* Storage Pools */}
            <div>
              <div className="flex items-center justify-between mb-3">
                <h2 className="text-xs text-nx-fg2 uppercase tracking-wider flex items-center gap-2">
                  <HardDrive size={13} /> Storage Pools
                </h2>
                <button className="nx-btn-ghost flex items-center gap-1.5 text-xs" onClick={() => setShowAddPool(true)}>
                  <Plus size={12} /> Add Pool
                </button>
              </div>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                {pools.map(pool => (
                  <div key={pool.id} className="nx-card p-5 space-y-3">
                    <div className="flex items-start justify-between">
                      <div>
                        <div className="font-medium text-nx-fg">{pool.name}</div>
                        <div className="text-xs text-nx-fg2 font-mono mt-0.5">{pool.path}</div>
                      </div>
                      <div className="flex items-center gap-2">
                        <span className={`text-[10px] px-2 py-0.5 rounded uppercase tracking-wider ${pool.active ? 'bg-nx-green/10 text-nx-green' : 'bg-nx-red/10 text-nx-red'}`}>
                          {pool.type}
                        </span>
                        {!pool.builtin && (
                          <button className="text-nx-fg2 hover:text-nx-red transition-colors" onClick={() => removePool(pool.id)}>
                            <X size={12} />
                          </button>
                        )}
                      </div>
                    </div>
                    {pool.capacity_gb > 0 && (
                      <>
                        <NxGauge
                          label="Used"
                          value={pool.used_gb}
                          max={pool.capacity_gb}
                          unit=" GB"
                          percent={Math.round((pool.used_gb / pool.capacity_gb) * 100)}
                        />
                        <div className="text-xs text-nx-fg2">{pool.available_gb.toFixed(1)} GB available of {pool.capacity_gb.toFixed(1)} GB</div>
                      </>
                    )}
                  </div>
                ))}
              </div>
            </div>

            {/* ISO Library */}
            <div>
              <div className="flex items-center justify-between mb-3">
                <h2 className="text-xs text-nx-fg2 uppercase tracking-wider flex items-center gap-2">
                  <FolderOpen size={13} /> ISO Library
                </h2>
                <div className="flex items-center gap-2">
                  <button
                    className="nx-btn-ghost flex items-center gap-1.5 text-xs"
                    onClick={() => setShowCatalog(true)}
                  >
                    <Globe size={12} /> ISO Catalog
                  </button>
                  <input type="file" accept=".iso" ref={fileRef} className="hidden" onChange={uploadISO} />
                  <button
                    className="nx-btn-primary flex items-center gap-2 text-xs"
                    onClick={() => fileRef.current?.click()}
                    disabled={uploading}
                  >
                    {uploading ? <NxSpinner size={14} /> : <Upload size={14} />}
                    Upload ISO
                  </button>
                </div>
              </div>
              <div className="nx-card overflow-hidden">
                {isos.length === 0 ? (
                  <div className="py-12 text-center space-y-2">
                    <div className="text-nx-fg2 text-xs tracking-widest uppercase">No ISO files</div>
                    <div className="text-nx-fg2 text-[10px]">Upload an ISO or download from the catalog.</div>
                  </div>
                ) : (
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-nx-border text-[10px] text-nx-fg2 uppercase tracking-wider">
                        <th className="text-left px-5 py-3">Filename</th>
                        <th className="text-left px-4 py-3">Size</th>
                        <th className="text-right px-5 py-3">Actions</th>
                      </tr>
                    </thead>
                    <tbody>
                      {isos.map(iso => (
                        <tr key={iso.name} className="border-b border-nx-border/50">
                          <td className="px-5 py-3 font-mono text-nx-fg text-xs">{iso.name}</td>
                          <td className="px-4 py-3 text-nx-fg2 text-xs">
                            {iso.size_mb >= 1024 ? `${(iso.size_mb / 1024).toFixed(1)} GB` : `${iso.size_mb} MB`}
                          </td>
                          <td className="px-5 py-3 text-right">
                            <button className="nx-btn-ghost p-1.5" onClick={() => deleteISO(iso.name)}>
                              <Trash2 size={13} className="text-nx-red/70 hover:text-nx-red" />
                            </button>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </div>
            </div>
          </>
        )}
      </div>

      {/* Add Pool Modal */}
      {showAddPool && (
        <AddPoolModal onClose={() => setShowAddPool(false)} onAdded={() => { setShowAddPool(false); fetch() }} />
      )}

      {/* ISO Catalog Modal */}
      {showCatalog && (
        <NxModal title="ISO Catalog" onClose={() => setShowCatalog(false)} width="max-w-3xl">
          <div className="space-y-4">
            {categories.map(cat => (
              <div key={cat}>
                <div className="text-[10px] text-nx-orange uppercase tracking-widest mb-2">{cat}</div>
                <div className="space-y-1">
                  {catalog.filter(c => c.category === cat).map(item => {
                    const dl = downloading[item.id]
                    const inProgress = dl && !('done' in dl) && !('error' in dl)
                    const isDone = dl && 'done' in dl
                    const isError = dl && 'error' in dl
                    return (
                      <div key={item.id} className="nx-card p-3 flex items-center gap-4">
                        <div className="flex-1 min-w-0">
                          <div className="text-xs text-nx-fg font-medium">{item.name}</div>
                          <div className="text-[10px] text-nx-fg2 mt-0.5">
                            v{item.version} · {item.size_gb} GB
                            {item.note && <span className="ml-2 text-nx-yellow">{item.note}</span>}
                          </div>
                          {inProgress && 'progress' in dl && (
                            <div className="mt-1.5">
                              <div className="flex justify-between text-[10px] text-nx-fg2 mb-1">
                                <span>{dl.downloaded_mb.toFixed(0)} / {dl.total_mb.toFixed(0)} MB</span>
                                <span>{dl.progress}%</span>
                              </div>
                              <div className="h-1 bg-nx-border rounded-full overflow-hidden">
                                <div className="h-full bg-nx-orange transition-all rounded-full" style={{ width: `${dl.progress}%` }} />
                              </div>
                            </div>
                          )}
                          {isDone && <div className="text-[10px] text-nx-green mt-1 flex items-center gap-1"><CheckCircle size={10} /> Download complete</div>}
                          {isError && 'error' in dl && <div className="text-[10px] text-nx-red mt-1 flex items-center gap-1"><AlertCircle size={10} /> {dl.error}</div>}
                        </div>
                        <div className="shrink-0 flex items-center gap-2">
                          {item.downloaded && !inProgress && (
                            <span className="text-[10px] text-nx-green flex items-center gap-1"><CheckCircle size={10} /> On disk</span>
                          )}
                          {item.url && !inProgress && (
                            <button
                              className="nx-btn-ghost flex items-center gap-1.5 text-xs"
                              onClick={() => downloadFromCatalog(item)}
                            >
                              <Download size={12} />
                              {item.downloaded ? 'Re-download' : 'Download'}
                            </button>
                          )}
                          {inProgress && <NxSpinner size={14} />}
                        </div>
                      </div>
                    )
                  })}
                </div>
              </div>
            ))}
          </div>
        </NxModal>
      )}
    </AppLayout>
  )
}

// ── Add Pool Modal ────────────────────────────────────────────────────────────

function AddPoolModal({ onClose, onAdded }: { onClose: () => void; onAdded: () => void }) {
  const [type, setType] = useState('local')
  const [name, setName] = useState('')
  const [path, setPath] = useState('')
  const [server, setServer] = useState('')
  const [share, setShare] = useState('')
  const [options, setOptions] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function submit() {
    if (!name.trim()) { setError('Name is required.'); return }
    if (type === 'local' && !path.trim()) { setError('Path is required.'); return }
    if (type === 'nfs' && (!server.trim() || !share.trim())) { setError('Server and share are required for NFS.'); return }
    setLoading(true)
    setError(null)
    try {
      await api.post('/storage/pools', { type, name: name.trim(), path: path.trim(), server: server.trim(), share: share.trim(), options: options.trim() })
      onAdded()
    } catch (e) {
      setError((e as Error).message)
    } finally { setLoading(false) }
  }

  return (
    <NxModal title="Add Storage Pool" onClose={onClose} width="max-w-lg">
      <div className="space-y-4">
        <div>
          <label className="block text-[10px] text-nx-fg2 uppercase tracking-wider mb-1.5">Pool Type</label>
          <select className="nx-input" value={type} onChange={e => setType(e.target.value)}>
            <option value="local">Local Directory</option>
            <option value="nfs">NFS Share</option>
          </select>
        </div>
        <div>
          <label className="block text-[10px] text-nx-fg2 uppercase tracking-wider mb-1.5">Pool Name</label>
          <input className="nx-input" placeholder="my-pool" value={name} onChange={e => setName(e.target.value)} />
        </div>
        {type === 'local' && (
          <div>
            <label className="block text-[10px] text-nx-fg2 uppercase tracking-wider mb-1.5">Directory Path</label>
            <input className="nx-input font-mono" placeholder="/data/vms" value={path} onChange={e => setPath(e.target.value)} />
          </div>
        )}
        {type === 'nfs' && (
          <>
            <div>
              <label className="block text-[10px] text-nx-fg2 uppercase tracking-wider mb-1.5">NFS Server</label>
              <input className="nx-input font-mono" placeholder="192.168.1.100" value={server} onChange={e => setServer(e.target.value)} />
            </div>
            <div>
              <label className="block text-[10px] text-nx-fg2 uppercase tracking-wider mb-1.5">Share Path</label>
              <input className="nx-input font-mono" placeholder="/exports/vms" value={share} onChange={e => setShare(e.target.value)} />
            </div>
            <div>
              <label className="block text-[10px] text-nx-fg2 uppercase tracking-wider mb-1.5">Mount Options (optional)</label>
              <input className="nx-input font-mono" placeholder="defaults,_netdev" value={options} onChange={e => setOptions(e.target.value)} />
            </div>
          </>
        )}
        {error && <div className="text-nx-red text-xs">{error}</div>}
        <div className="flex gap-3 justify-end pt-1">
          <button className="nx-btn-ghost text-xs" onClick={onClose}>Cancel</button>
          <button className="nx-btn-primary flex items-center gap-2 text-xs" onClick={submit} disabled={loading}>
            {loading && <NxSpinner size={13} />}
            Add Pool
          </button>
        </div>
      </div>
    </NxModal>
  )
}
