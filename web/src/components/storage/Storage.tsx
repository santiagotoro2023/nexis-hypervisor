import { useState, useEffect, useRef } from 'react'
import { Upload, Trash2, HardDrive, FolderOpen, Download, Plus, X, Globe, CheckCircle,
         AlertCircle, ChevronRight, Folder, File, ArrowLeft, FolderPlus, Edit2, Move } from 'lucide-react'
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

interface BrowseEntry {
  name: string
  type: 'file' | 'directory'
  size_bytes: number
  modified: string
}

interface BrowseResult {
  path: string
  parent: string | null
  entries: BrowseEntry[]
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

type DownloadState =
  | { progress: number; downloaded_mb: number; total_mb: number }
  | { done: boolean; name: string }
  | { error: string }
  | null

export function Storage() {
  const [pools, setPools] = useState<Pool[]>([])
  const [isos, setIsos] = useState<ISOFile[]>([])
  const [catalog, setCatalog] = useState<CatalogItem[]>([])
  const [loading, setLoading] = useState(true)
  const [uploading, setUploading] = useState(false)
  const [showAddPool, setShowAddPool] = useState(false)
  const [showCatalog, setShowCatalog] = useState(false)
  const [showBrowser, setShowBrowser] = useState(false)
  const [browsePath, setBrowsePath] = useState<string | null>(null)
  const [downloading, setDownloading] = useState<Record<string, DownloadState>>({})
  const fileRef = useRef<HTMLInputElement>(null)
  // Track active abort controllers keyed by catalog item id
  const abortRefs = useRef<Record<string, AbortController>>({})

  const fetchData = () =>
    Promise.all([
      api.get<Pool[]>('/storage/pools').then(setPools),
      api.get<ISOFile[]>('/storage/isos/list').then(setIsos),
      api.get<CatalogItem[]>('/storage/catalog').then(setCatalog),
    ]).finally(() => setLoading(false))

  useEffect(() => { fetchData() }, [])

  async function uploadISO(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    setUploading(true)
    const form = new FormData()
    form.append('file', file)
    try { await api.postForm('/storage/isos/upload', form) } finally {
      setUploading(false)
      fetchData()
      // Reset file input so the same file can be re-selected
      if (fileRef.current) fileRef.current.value = ''
    }
  }

  async function deleteISO(name: string) {
    if (!confirm(`Delete ISO "${name}"?`)) return
    await api.delete(`/storage/isos/${encodeURIComponent(name)}`)
    fetchData()
  }

  async function removePool(id: string) {
    if (!confirm('Remove this storage pool?')) return
    await api.delete(`/storage/pools/${id}`)
    fetchData()
  }

  async function downloadFromCatalog(item: CatalogItem) {
    if (!item.url) return
    const key = item.id

    // Cancel any existing download for this item
    if (abortRefs.current[key]) {
      abortRefs.current[key].abort()
    }

    const controller = new AbortController()
    abortRefs.current[key] = controller

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
        signal: controller.signal,
      })

      if (!res.ok || !res.body) {
        const msg = await res.text().catch(() => 'Unknown error')
        setDownloading(d => ({ ...d, [key]: { error: msg } }))
        return
      }

      const reader = res.body.getReader()
      const decoder = new TextDecoder()
      let buf = ''

      // eslint-disable-next-line no-constant-condition
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buf += decoder.decode(value, { stream: true })
        // SSE events are separated by double newlines
        const events = buf.split('\n\n')
        buf = events.pop() ?? ''
        for (const event of events) {
          for (const line of event.split('\n')) {
            if (!line.startsWith('data: ')) continue
            try {
              const ev = JSON.parse(line.slice(6))
              setDownloading(d => ({ ...d, [key]: ev }))
            } catch { /* skip malformed */ }
          }
        }
      }
    } catch (e) {
      if ((e as Error).name !== 'AbortError') {
        setDownloading(d => ({ ...d, [key]: { error: (e as Error).message } }))
      }
    } finally {
      delete abortRefs.current[key]
    }

    setTimeout(() => {
      setDownloading(d => { const n = { ...d }; delete n[key]; return n })
      fetchData()
    }, 3000)
  }

  function cancelDownload(key: string) {
    abortRefs.current[key]?.abort()
    delete abortRefs.current[key]
    setDownloading(d => { const n = { ...d }; delete n[key]; return n })
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
                        <button
                          className="text-nx-fg2 hover:text-nx-orange transition-colors"
                          title="Browse"
                          onClick={() => { setBrowsePath(pool.path); setShowBrowser(true) }}
                        >
                          <FolderOpen size={12} />
                        </button>
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
        <AddPoolModal onClose={() => setShowAddPool(false)} onAdded={() => { setShowAddPool(false); fetchData() }} />
      )}

      {/* Storage Browser Modal */}
      {showBrowser && browsePath && (
        <StorageBrowser path={browsePath} onClose={() => setShowBrowser(false)} />
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
                          {inProgress && (
                            <>
                              <NxSpinner size={14} />
                              <button
                                className="nx-btn-ghost flex items-center gap-1 text-xs text-nx-red"
                                onClick={() => cancelDownload(item.id)}
                              >
                                <X size={11} /> Cancel
                              </button>
                            </>
                          )}
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

// ── Storage Browser ───────────────────────────────────────────────────────────

function StorageBrowser({ path, onClose }: { path: string; onClose: () => void }) {
  const [browse, setBrowse] = useState<BrowseResult | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [clipboard, setClipboard] = useState<{ path: string; name: string; op: 'copy' | 'move' } | null>(null)
  const [showNewFolder, setShowNewFolder] = useState(false)
  const [newFolderName, setNewFolderName] = useState('')
  const [showRename, setShowRename] = useState<BrowseEntry | null>(null)
  const [renameName, setRenameName] = useState('')
  const [actionLoading, setActionLoading] = useState(false)
  // Context menu for entries
  const [entryMenu, setEntryMenu] = useState<{ entry: BrowseEntry; x: number; y: number } | null>(null)
  const entryMenuRef = useRef<HTMLDivElement>(null)

  async function navigate(p: string) {
    setLoading(true)
    setError(null)
    try {
      const data = await api.get<BrowseResult>(`/storage/browse?path=${encodeURIComponent(p)}`)
      setBrowse(data)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { navigate(path) }, [path])

  // Close entry context menu on outside click
  useEffect(() => {
    function handler(e: MouseEvent) {
      if (entryMenuRef.current && !entryMenuRef.current.contains(e.target as Node)) {
        setEntryMenu(null)
      }
    }
    if (entryMenu) {
      document.addEventListener('mousedown', handler)
      return () => document.removeEventListener('mousedown', handler)
    }
  }, [entryMenu])

  function formatSize(bytes: number) {
    if (bytes === 0) return '—'
    if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(1)} GB`
    if (bytes >= 1024 ** 2) return `${(bytes / 1024 ** 2).toFixed(1)} MB`
    return `${(bytes / 1024).toFixed(1)} KB`
  }

  const currentPath = browse?.path ?? path
  const pathParts = currentPath.split('/').filter(Boolean)

  async function createFolder() {
    if (!newFolderName.trim() || !browse) return
    setActionLoading(true)
    try {
      await api.post('/storage/fs/mkdir', { path: `${browse.path}/${newFolderName.trim()}` })
      setShowNewFolder(false)
      setNewFolderName('')
      navigate(browse.path)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setActionLoading(false)
    }
  }

  async function deleteEntry(entry: BrowseEntry) {
    if (!browse) return
    const label = entry.type === 'directory' ? `folder "${entry.name}" and all its contents` : `file "${entry.name}"`
    if (!confirm(`Permanently delete ${label}?`)) return
    setActionLoading(true)
    try {
      await api.post('/storage/fs/delete', { path: `${browse.path}/${entry.name}` })
      navigate(browse.path)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setActionLoading(false)
    }
  }

  async function renameEntry() {
    if (!showRename || !renameName.trim() || !browse) return
    setActionLoading(true)
    try {
      await api.post('/storage/fs/rename', {
        src: `${browse.path}/${showRename.name}`,
        dst: `${browse.path}/${renameName.trim()}`,
      })
      setShowRename(null)
      setRenameName('')
      navigate(browse.path)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setActionLoading(false)
    }
  }

  async function pasteEntry() {
    if (!clipboard || !browse) return
    setActionLoading(true)
    try {
      const dst = `${browse.path}/${clipboard.name}`
      if (clipboard.op === 'move') {
        await api.post('/storage/fs/rename', { src: clipboard.path, dst })
      } else {
        await api.post('/storage/fs/copy', { src: clipboard.path, dst })
      }
      setClipboard(null)
      navigate(browse.path)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setActionLoading(false)
    }
  }

  function openEntryMenu(e: React.MouseEvent, entry: BrowseEntry) {
    e.preventDefault()
    e.stopPropagation()
    const x = Math.min(e.clientX, window.innerWidth - 180)
    const y = Math.min(e.clientY, window.innerHeight - 200)
    setEntryMenu({ entry, x, y })
  }

  return (
    <NxModal title="Storage Browser" onClose={onClose} width="max-w-3xl">
      <div className="space-y-3">
        {/* Breadcrumb */}
        <div className="flex items-center gap-1 text-xs font-mono flex-wrap">
          <span className="text-nx-fg2">/</span>
          {pathParts.map((part, i) => {
            const p = '/' + pathParts.slice(0, i + 1).join('/')
            return (
              <span key={p} className="flex items-center gap-1">
                <button className="text-nx-orange hover:underline" onClick={() => navigate(p)}>{part}</button>
                {i < pathParts.length - 1 && <ChevronRight size={10} className="text-nx-fg2" />}
              </span>
            )
          })}
        </div>

        {/* Toolbar */}
        <div className="flex items-center gap-2 flex-wrap">
          {browse?.parent && (
            <button
              className="flex items-center gap-1.5 text-xs text-nx-fg2 hover:text-nx-fg transition-colors"
              onClick={() => navigate(browse.parent!)}
            >
              <ArrowLeft size={12} /> Parent
            </button>
          )}
          <button
            className="flex items-center gap-1.5 text-xs nx-btn-ghost"
            onClick={() => { setShowNewFolder(true); setNewFolderName('') }}
          >
            <FolderPlus size={12} /> New Folder
          </button>
          {clipboard && (
            <button
              className="flex items-center gap-1.5 text-xs nx-btn-ghost text-nx-orange"
              onClick={pasteEntry}
              disabled={actionLoading}
            >
              <Move size={12} /> Paste {clipboard.op === 'move' ? '(Move)' : '(Copy)'}: {clipboard.name}
            </button>
          )}
          {actionLoading && <NxSpinner size={14} />}
        </div>

        {/* New folder form */}
        {showNewFolder && (
          <div className="flex items-center gap-2">
            <input
              autoFocus
              className="nx-input text-xs flex-1"
              placeholder="Folder name"
              value={newFolderName}
              onChange={e => setNewFolderName(e.target.value)}
              onKeyDown={e => { if (e.key === 'Enter') createFolder(); if (e.key === 'Escape') setShowNewFolder(false) }}
            />
            <button className="nx-btn-primary text-xs" onClick={createFolder} disabled={!newFolderName.trim() || actionLoading}>Create</button>
            <button className="nx-btn-ghost text-xs" onClick={() => setShowNewFolder(false)}>Cancel</button>
          </div>
        )}

        {/* Rename form */}
        {showRename && (
          <div className="flex items-center gap-2">
            <span className="text-xs text-nx-fg2">Rename "{showRename.name}" to:</span>
            <input
              autoFocus
              className="nx-input text-xs flex-1"
              value={renameName}
              onChange={e => setRenameName(e.target.value)}
              onKeyDown={e => { if (e.key === 'Enter') renameEntry(); if (e.key === 'Escape') setShowRename(null) }}
            />
            <button className="nx-btn-primary text-xs" onClick={renameEntry} disabled={!renameName.trim() || actionLoading}>Rename</button>
            <button className="nx-btn-ghost text-xs" onClick={() => setShowRename(null)}>Cancel</button>
          </div>
        )}

        {loading && <div className="flex items-center justify-center py-10"><NxSpinner size={24} /></div>}
        {error && <div className="text-nx-red text-xs">{error}</div>}

        {!loading && browse && (
          <div className="nx-card overflow-hidden">
            {browse.entries.length === 0 ? (
              <div className="py-8 text-center text-nx-fg2 text-xs">Empty directory</div>
            ) : (
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-nx-border text-[10px] text-nx-fg2 uppercase tracking-wider">
                    <th className="text-left px-5 py-3">Name</th>
                    <th className="text-left px-4 py-3">Size</th>
                    <th className="text-left px-4 py-3">Modified</th>
                    <th className="text-right px-4 py-3">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {browse.entries.map(entry => (
                    <tr
                      key={entry.name}
                      className="border-b border-nx-border/50 hover:bg-nx-dim/30 transition-colors"
                      onContextMenu={e => openEntryMenu(e, entry)}
                    >
                      <td className="px-5 py-2.5">
                        {entry.type === 'directory' ? (
                          <button
                            className="flex items-center gap-2 text-xs text-nx-orange hover:underline font-mono"
                            onClick={() => navigate(`${browse.path}/${entry.name}`)}
                          >
                            <Folder size={12} />
                            {entry.name}/
                          </button>
                        ) : (
                          <span className="flex items-center gap-2 text-xs text-nx-fg font-mono">
                            <File size={12} className="text-nx-fg2" />
                            {entry.name}
                          </span>
                        )}
                      </td>
                      <td className="px-4 py-2.5 text-xs text-nx-fg2">
                        {entry.type === 'directory' ? '—' : formatSize(entry.size_bytes)}
                      </td>
                      <td className="px-4 py-2.5 text-xs text-nx-fg2">
                        {new Date(entry.modified).toLocaleDateString()}
                      </td>
                      <td className="px-4 py-2.5 text-right">
                        <div className="flex items-center justify-end gap-1">
                          <button
                            className="nx-btn-ghost p-1" title="Rename"
                            onClick={() => { setShowRename(entry); setRenameName(entry.name) }}
                          >
                            <Edit2 size={11} />
                          </button>
                          <button
                            className="nx-btn-ghost p-1" title="Copy"
                            onClick={() => setClipboard({ path: `${browse.path}/${entry.name}`, name: entry.name, op: 'copy' })}
                          >
                            <File size={11} />
                          </button>
                          <button
                            className="nx-btn-ghost p-1" title="Cut (Move)"
                            onClick={() => setClipboard({ path: `${browse.path}/${entry.name}`, name: entry.name, op: 'move' })}
                          >
                            <Move size={11} />
                          </button>
                          <button
                            className="nx-btn-ghost p-1 text-nx-red/70 hover:text-nx-red" title="Delete"
                            onClick={() => deleteEntry(entry)}
                          >
                            <Trash2 size={11} />
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        )}
      </div>

      {/* Entry right-click context menu */}
      {entryMenu && (
        <div
          ref={entryMenuRef}
          className="fixed bg-nx-surface border border-nx-border rounded-lg shadow-xl py-1 text-xs w-44"
          style={{ left: entryMenu.x, top: entryMenu.y, zIndex: 9999 }}
        >
          <div className="px-3 py-1.5 border-b border-nx-border/50 text-nx-fg font-mono text-[10px] truncate">
            {entryMenu.entry.name}
          </div>
          <button className="w-full flex items-center gap-2 px-3 py-1.5 text-nx-fg2 hover:bg-nx-dim hover:text-nx-fg"
            onClick={() => { setShowRename(entryMenu.entry); setRenameName(entryMenu.entry.name); setEntryMenu(null) }}>
            <Edit2 size={11} /> Rename
          </button>
          <button className="w-full flex items-center gap-2 px-3 py-1.5 text-nx-fg2 hover:bg-nx-dim hover:text-nx-fg"
            onClick={() => {
              setClipboard({ path: `${browse!.path}/${entryMenu.entry.name}`, name: entryMenu.entry.name, op: 'copy' })
              setEntryMenu(null)
            }}>
            <File size={11} /> Copy
          </button>
          <button className="w-full flex items-center gap-2 px-3 py-1.5 text-nx-fg2 hover:bg-nx-dim hover:text-nx-fg"
            onClick={() => {
              setClipboard({ path: `${browse!.path}/${entryMenu.entry.name}`, name: entryMenu.entry.name, op: 'move' })
              setEntryMenu(null)
            }}>
            <Move size={11} /> Cut (Move)
          </button>
          <div className="border-t border-nx-border/30 mt-1 pt-1" />
          <button className="w-full flex items-center gap-2 px-3 py-1.5 text-nx-red hover:bg-nx-red/10"
            onClick={() => { deleteEntry(entryMenu.entry); setEntryMenu(null) }}>
            <Trash2 size={11} /> Delete
          </button>
        </div>
      )}
    </NxModal>
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
