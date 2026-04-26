import { useState, useEffect, useRef } from 'react'
import { Upload, Trash2, HardDrive, FolderOpen } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { NxSpinner } from '../common/NxSpinner'
import { NxGauge } from '../common/NxGauge'
import { api } from '../../api/client'

interface Pool {
  name: string
  path: string
  capacity_gb: number
  used_gb: number
  available_gb: number
  type: string
  active: boolean
}

interface ISOFile {
  name: string
  size_mb: number
  path: string
}

export function Storage() {
  const [pools, setPools] = useState<Pool[]>([])
  const [isos, setIsos] = useState<ISOFile[]>([])
  const [loading, setLoading] = useState(true)
  const [uploading, setUploading] = useState(false)
  const fileRef = useRef<HTMLInputElement>(null)

  const fetch = () =>
    Promise.all([
      api.get<Pool[]>('/storage/pools').then(setPools),
      api.get<ISOFile[]>('/storage/isos/list').then(setIsos),
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

  return (
    <AppLayout title="Storage">
      <div className="space-y-6">
        {loading ? (
          <div className="flex items-center justify-center py-20"><NxSpinner size={32} /></div>
        ) : (
          <>
            {/* Pools */}
            <div>
              <h2 className="text-xs text-nx-fg2 uppercase tracking-wider mb-3 flex items-center gap-2">
                <HardDrive size={13} /> Storage Pools
              </h2>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                {pools.map(pool => (
                  <div key={pool.name} className="nx-card p-5 space-y-3">
                    <div className="flex items-start justify-between">
                      <div>
                        <div className="font-medium text-nx-fg">{pool.name}</div>
                        <div className="text-xs text-nx-fg2 font-mono mt-0.5">{pool.path}</div>
                      </div>
                      <span className={`text-xs px-2 py-0.5 rounded ${pool.active ? 'bg-nx-green/10 text-nx-green' : 'bg-nx-red/10 text-nx-red'}`}>
                        {pool.type}
                      </span>
                    </div>
                    <NxGauge
                      label="Used"
                      value={pool.used_gb}
                      max={pool.capacity_gb}
                      unit=" GB"
                      percent={Math.round((pool.used_gb / pool.capacity_gb) * 100)}
                    />
                    <div className="text-xs text-nx-fg2">{pool.available_gb.toFixed(1)} GB available</div>
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
                <div>
                  <input type="file" accept=".iso" ref={fileRef} className="hidden" onChange={uploadISO} />
                  <button
                    className="nx-btn-primary flex items-center gap-2"
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
                  <div className="py-12 text-center text-nx-fg2 text-sm">No ISO files. Upload one to get started.</div>
                ) : (
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b border-nx-border text-xs text-nx-fg2 uppercase tracking-wider">
                        <th className="text-left px-5 py-3">Filename</th>
                        <th className="text-left px-4 py-3">Size</th>
                        <th className="text-right px-5 py-3">Actions</th>
                      </tr>
                    </thead>
                    <tbody>
                      {isos.map(iso => (
                        <tr key={iso.name} className="border-b border-nx-border/50">
                          <td className="px-5 py-3 font-mono text-nx-fg text-xs">{iso.name}</td>
                          <td className="px-4 py-3 text-nx-fg2 text-xs">{iso.size_mb >= 1024 ? `${(iso.size_mb / 1024).toFixed(1)} GB` : `${iso.size_mb} MB`}</td>
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
    </AppLayout>
  )
}
