export interface VM {
  id: string
  name: string
  status: 'running' | 'stopped' | 'paused' | 'suspended' | 'crashed' | 'unknown'
  vcpus: number
  memory_mb: number
  disk_gb: number
  os: string
  ip?: string
  vnc_port?: number
  cpu_percent?: number
  memory_percent?: number
}

export interface VMSnapshot {
  name: string
  created: string
  description?: string
}

export interface DiskSpec {
  size_gb: number
  bus: 'virtio' | 'sata' | 'ide' | 'scsi'
  format: 'qcow2' | 'raw'
}

export interface NicSpec {
  network: string
  model: 'virtio' | 'e1000' | 'rtl8139'
}

export interface CreateVMPayload {
  name: string
  vcpus: number
  sockets: number
  cores: number
  threads: number
  memory_mb: number
  disk_gb: number
  disks: DiskSpec[]
  nics: NicSpec[]
  os: string
  os_iso?: string
  network: string
  machine: string
  cpu_mode: string
  display: string
  video: string
  boot_order: string[]
  enable_kvm: boolean
  balloon: boolean
}
