import { useState, useEffect } from 'react'
import { Plus, Trash2 } from 'lucide-react'
import { NxSpinner } from '../common/NxSpinner'
import { CreateVMPayload, DiskSpec, NicSpec } from './types'
import { api } from '../../api/client'

interface Props {
  onSubmit: (payload: CreateVMPayload) => Promise<void>
  onCancel: () => void
}

const TABS = ['General', 'System', 'CPU', 'Memory', 'Disks', 'Network', 'Display'] as const
type Tab = typeof TABS[number]

const defaultDisk = (): DiskSpec => ({ size_gb: 20, bus: 'virtio', format: 'qcow2' })
const defaultNic = (): NicSpec => ({ network: 'default', model: 'virtio' })

export function CreateVMForm({ onSubmit, onCancel }: Props) {
  const [tab, setTab] = useState<Tab>('General')
  const [isos, setIsos] = useState<string[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const [name, setName] = useState('')
  const [os, setOs] = useState('linux')
  const [osIso, setOsIso] = useState('')
  const [machine, setMachine] = useState('q35')
  const [cpuMode, setCpuMode] = useState('host-model')
  const [enableKvm, setEnableKvm] = useState(true)
  const [balloon, setBalloon] = useState(true)
  const [sockets, setSockets] = useState(1)
  const [cores, setCores] = useState(2)
  const [threads, setThreads] = useState(1)
  const [memoryMb, setMemoryMb] = useState(2048)
  const [disks, setDisks] = useState<DiskSpec[]>([defaultDisk()])
  const [nics, setNics] = useState<NicSpec[]>([defaultNic()])
  const [display, setDisplay] = useState('vnc')
  const [video, setVideo] = useState('qxl')
  const [bootOrder, setBootOrder] = useState<string[]>(['cdrom', 'hd'])

  useEffect(() => {
    api.get<{ isos: string[] }>('/storage/isos').then(d => setIsos(d.isos)).catch(() => {})
  }, [])

  const totalVcpus = sockets * cores * threads

  function addDisk() { setDisks(d => [...d, defaultDisk()]) }
  function removeDisk(i: number) { setDisks(d => d.filter((_, idx) => idx !== i)) }
  function updateDisk(i: number, field: keyof DiskSpec, val: unknown) {
    setDisks(d => d.map((dk, idx) => idx === i ? { ...dk, [field]: val } : dk))
  }

  function addNic() { setNics(n => [...n, defaultNic()]) }
  function removeNic(i: number) { setNics(n => n.filter((_, idx) => idx !== i)) }
  function updateNic(i: number, field: keyof NicSpec, val: string) {
    setNics(n => n.map((nic, idx) => idx === i ? { ...nic, [field]: val } : nic))
  }

  function toggleBootDev(dev: string) {
    setBootOrder(prev =>
      prev.includes(dev) ? prev.filter(b => b !== dev) : [...prev, dev]
    )
  }

  function moveBootDev(dev: string, dir: -1 | 1) {
    setBootOrder(prev => {
      const arr = [...prev]
      const idx = arr.indexOf(dev)
      if (idx < 0) return arr
      const next = idx + dir
      if (next < 0 || next >= arr.length) return arr
      ;[arr[idx], arr[next]] = [arr[next], arr[idx]]
      return arr
    })
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!name.trim()) { setError('Name is required'); setTab('General'); return }
    if (disks.length === 0) { setError('At least one disk is required'); setTab('Disks'); return }
    setLoading(true)
    setError(null)
    try {
      await onSubmit({
        name: name.trim(),
        vcpus: totalVcpus,
        sockets, cores, threads,
        memory_mb: memoryMb,
        disk_gb: disks[0]?.size_gb ?? 20,
        disks,
        nics,
        os,
        os_iso: osIso || undefined,
        network: nics[0]?.network ?? 'default',
        machine,
        cpu_mode: cpuMode,
        display,
        video,
        boot_order: bootOrder,
        enable_kvm: enableKvm,
        balloon,
      })
    } catch (ex) {
      setError((ex as Error).message)
    } finally {
      setLoading(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      {/* Tab bar */}
      <div className="flex gap-0 border-b border-nx-border overflow-x-auto">
        {TABS.map(t => (
          <button
            key={t}
            type="button"
            onClick={() => setTab(t)}
            className={`px-4 py-2 text-[10px] tracking-widest uppercase whitespace-nowrap transition-colors border-b-2 -mb-px ${
              tab === t
                ? 'border-nx-orange text-nx-orange'
                : 'border-transparent text-nx-fg2 hover:text-nx-fg'
            }`}
          >
            {t}
          </button>
        ))}
      </div>

      {/* Tab content */}
      <div className="min-h-[220px]">

        {tab === 'General' && (
          <div className="grid grid-cols-2 gap-4">
            <div className="col-span-2">
              <label className="nx-label">Instance Name</label>
              <input className="nx-input" placeholder="my-vm" value={name} onChange={e => setName(e.target.value)} autoFocus />
            </div>
            <div>
              <label className="nx-label">OS Type</label>
              <select className="nx-input" value={os} onChange={e => setOs(e.target.value)}>
                <option value="linux">Linux</option>
                <option value="windows">Windows</option>
                <option value="other">Other</option>
              </select>
            </div>
            <div>
              <label className="nx-label">Boot ISO</label>
              <select className="nx-input" value={osIso} onChange={e => setOsIso(e.target.value)}>
                <option value="">— No ISO —</option>
                {isos.map(iso => <option key={iso} value={iso}>{iso}</option>)}
              </select>
            </div>
          </div>
        )}

        {tab === 'System' && (
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="nx-label">Machine Type</label>
              <select className="nx-input" value={machine} onChange={e => setMachine(e.target.value)}>
                <option value="q35">q35 (recommended)</option>
                <option value="pc">i440fx (legacy)</option>
              </select>
            </div>
            <div>
              <label className="nx-label">CPU Mode</label>
              <select className="nx-input" value={cpuMode} onChange={e => setCpuMode(e.target.value)}>
                <option value="host-model">host-model (recommended)</option>
                <option value="host-passthrough">host-passthrough</option>
                <option value="custom">custom</option>
              </select>
            </div>
            <div className="flex items-center gap-3 col-span-2">
              <label className="nx-label mb-0 cursor-pointer flex items-center gap-2">
                <input type="checkbox" checked={enableKvm} onChange={e => setEnableKvm(e.target.checked)}
                  className="accent-nx-orange w-4 h-4" />
                Enable KVM Hardware Acceleration
              </label>
            </div>
            <div className="flex items-center gap-3 col-span-2">
              <label className="nx-label mb-0 cursor-pointer flex items-center gap-2">
                <input type="checkbox" checked={balloon} onChange={e => setBalloon(e.target.checked)}
                  className="accent-nx-orange w-4 h-4" />
                Enable VirtIO Memory Balloon
              </label>
            </div>
          </div>
        )}

        {tab === 'CPU' && (
          <div className="grid grid-cols-3 gap-4">
            <div>
              <label className="nx-label">Sockets</label>
              <input type="number" min={1} max={8} className="nx-input" value={sockets}
                onChange={e => setSockets(+e.target.value)} />
            </div>
            <div>
              <label className="nx-label">Cores / Socket</label>
              <input type="number" min={1} max={64} className="nx-input" value={cores}
                onChange={e => setCores(+e.target.value)} />
            </div>
            <div>
              <label className="nx-label">Threads / Core</label>
              <input type="number" min={1} max={2} className="nx-input" value={threads}
                onChange={e => setThreads(+e.target.value)} />
            </div>
            <div className="col-span-3 pt-2 border-t border-nx-border/30">
              <div className="text-xs text-nx-fg2">
                Total vCPUs: <span className="text-nx-orange font-mono font-bold">{totalVcpus}</span>
                <span className="ml-4 opacity-60">({sockets}s × {cores}c × {threads}t)</span>
              </div>
            </div>
          </div>
        )}

        {tab === 'Memory' && (
          <div className="grid grid-cols-2 gap-4">
            <div className="col-span-2">
              <label className="nx-label">Memory (MB)</label>
              <input type="number" min={256} step={256} className="nx-input" value={memoryMb}
                onChange={e => setMemoryMb(+e.target.value)} />
              <div className="text-xs text-nx-fg2 mt-1.5 font-mono">
                = {(memoryMb / 1024).toFixed(2)} GB
              </div>
            </div>
            <div className="col-span-2">
              <label className="nx-label">Quick Presets</label>
              <div className="flex flex-wrap gap-2">
                {[512, 1024, 2048, 4096, 8192, 16384, 32768].map(mb => (
                  <button key={mb} type="button"
                    onClick={() => setMemoryMb(mb)}
                    className={`px-3 py-1 rounded text-[10px] tracking-widest uppercase border transition-colors ${
                      memoryMb === mb
                        ? 'bg-nx-orange/10 text-nx-orange border-nx-orange/30'
                        : 'border-nx-border text-nx-fg2 hover:border-nx-orange/30 hover:text-nx-fg'
                    }`}
                  >
                    {mb >= 1024 ? `${mb / 1024}G` : `${mb}M`}
                  </button>
                ))}
              </div>
            </div>
          </div>
        )}

        {tab === 'Disks' && (
          <div className="space-y-3">
            {disks.map((disk, i) => (
              <div key={i} className="grid grid-cols-7 gap-2 items-center p-3 rounded bg-nx-dim/30 border border-nx-border/30">
                <div className="col-span-1">
                  <label className="nx-label">Drive {i}</label>
                  <span className="text-xs text-nx-fg2 font-mono">
                    {disk.bus === 'virtio' ? `vd${String.fromCharCode(97 + i)}` :
                     disk.bus === 'sata' || disk.bus === 'scsi' ? `sd${String.fromCharCode(97 + i)}` :
                     `hd${String.fromCharCode(97 + i)}`}
                  </span>
                </div>
                <div className="col-span-2">
                  <label className="nx-label">Size (GB)</label>
                  <input type="number" min={1} className="nx-input" value={disk.size_gb}
                    onChange={e => updateDisk(i, 'size_gb', +e.target.value)} />
                </div>
                <div className="col-span-2">
                  <label className="nx-label">Bus</label>
                  <select className="nx-input" value={disk.bus}
                    onChange={e => updateDisk(i, 'bus', e.target.value)}>
                    <option value="virtio">VirtIO (fast)</option>
                    <option value="sata">SATA</option>
                    <option value="scsi">SCSI</option>
                    <option value="ide">IDE</option>
                  </select>
                </div>
                <div className="col-span-1">
                  <label className="nx-label">Format</label>
                  <select className="nx-input" value={disk.format}
                    onChange={e => updateDisk(i, 'format', e.target.value)}>
                    <option value="qcow2">qcow2</option>
                    <option value="raw">raw</option>
                  </select>
                </div>
                <div className="col-span-1 flex items-end pb-0.5">
                  <button type="button" disabled={disks.length === 1}
                    className="p-1.5 text-nx-red/60 hover:text-nx-red disabled:opacity-20 transition-colors"
                    onClick={() => removeDisk(i)}>
                    <Trash2 size={13} />
                  </button>
                </div>
              </div>
            ))}
            <button type="button" onClick={addDisk}
              className="flex items-center gap-2 text-xs text-nx-orange hover:text-nx-orange/80 transition-colors py-1">
              <Plus size={13} /> Add Disk
            </button>
          </div>
        )}

        {tab === 'Network' && (
          <div className="space-y-3">
            {nics.map((nic, i) => (
              <div key={i} className="grid grid-cols-5 gap-2 items-end p-3 rounded bg-nx-dim/30 border border-nx-border/30">
                <div className="col-span-1">
                  <label className="nx-label">NIC {i}</label>
                  <span className="text-xs text-nx-fg2 font-mono">eth{i}</span>
                </div>
                <div className="col-span-2">
                  <label className="nx-label">Network / Bridge</label>
                  <input className="nx-input" placeholder="default" value={nic.network}
                    onChange={e => updateNic(i, 'network', e.target.value)} />
                </div>
                <div className="col-span-1">
                  <label className="nx-label">Model</label>
                  <select className="nx-input" value={nic.model}
                    onChange={e => updateNic(i, 'model', e.target.value)}>
                    <option value="virtio">VirtIO</option>
                    <option value="e1000">e1000</option>
                    <option value="rtl8139">RTL8139</option>
                  </select>
                </div>
                <div className="col-span-1 flex justify-end">
                  <button type="button" disabled={nics.length === 1}
                    className="p-1.5 text-nx-red/60 hover:text-nx-red disabled:opacity-20 transition-colors"
                    onClick={() => removeNic(i)}>
                    <Trash2 size={13} />
                  </button>
                </div>
              </div>
            ))}
            <button type="button" onClick={addNic}
              className="flex items-center gap-2 text-xs text-nx-orange hover:text-nx-orange/80 transition-colors py-1">
              <Plus size={13} /> Add Network Interface
            </button>
          </div>
        )}

        {tab === 'Display' && (
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="nx-label">Display Type</label>
              <select className="nx-input" value={display} onChange={e => setDisplay(e.target.value)}>
                <option value="vnc">VNC</option>
                <option value="spice">SPICE</option>
              </select>
            </div>
            <div>
              <label className="nx-label">Video Model</label>
              <select className="nx-input" value={video} onChange={e => setVideo(e.target.value)}>
                <option value="qxl">QXL (recommended for SPICE)</option>
                <option value="vga">VGA</option>
                <option value="virtio">VirtIO GPU</option>
              </select>
            </div>
            <div className="col-span-2">
              <label className="nx-label">Boot Order</label>
              <div className="space-y-1.5 mt-1">
                {['cdrom', 'hd', 'network', 'fd'].map(dev => {
                  const active = bootOrder.includes(dev)
                  const idx = bootOrder.indexOf(dev)
                  return (
                    <div key={dev} className="flex items-center gap-3">
                      <input type="checkbox" id={`boot-${dev}`} checked={active}
                        className="accent-nx-orange w-4 h-4"
                        onChange={() => toggleBootDev(dev)} />
                      <label htmlFor={`boot-${dev}`}
                        className="text-xs text-nx-fg cursor-pointer w-24 uppercase tracking-wider">
                        {dev === 'hd' ? 'Hard Disk' : dev === 'fd' ? 'Floppy' :
                         dev === 'cdrom' ? 'CD-ROM' : 'Network'}
                      </label>
                      {active && (
                        <div className="flex gap-1">
                          <button type="button" onClick={() => moveBootDev(dev, -1)}
                            disabled={idx === 0}
                            className="text-[10px] px-1.5 py-0.5 rounded bg-nx-dim border border-nx-border hover:border-nx-orange/40 disabled:opacity-30 transition-colors">
                            ▲
                          </button>
                          <button type="button" onClick={() => moveBootDev(dev, 1)}
                            disabled={idx === bootOrder.length - 1}
                            className="text-[10px] px-1.5 py-0.5 rounded bg-nx-dim border border-nx-border hover:border-nx-orange/40 disabled:opacity-30 transition-colors">
                            ▼
                          </button>
                          <span className="text-[10px] text-nx-fg2 ml-1">#{idx + 1}</span>
                        </div>
                      )}
                    </div>
                  )
                })}
              </div>
            </div>
          </div>
        )}
      </div>

      {error && <div className="text-nx-red text-xs bg-nx-red/5 border border-nx-red/20 rounded px-3 py-2">{error}</div>}

      <div className="flex items-center justify-between pt-2 border-t border-nx-border/30">
        <div className="text-[10px] text-nx-fg2 font-mono">
          {totalVcpus} vCPU · {(memoryMb / 1024).toFixed(1)} GB RAM · {disks.reduce((a, d) => a + d.size_gb, 0)} GB disk
        </div>
        <div className="flex gap-3">
          <button type="button" className="nx-btn-ghost" onClick={onCancel}>Cancel</button>
          <button type="submit" className="nx-btn-primary flex items-center gap-2" disabled={loading}>
            {loading && <NxSpinner size={14} />}
            Provision
          </button>
        </div>
      </div>
    </form>
  )
}
