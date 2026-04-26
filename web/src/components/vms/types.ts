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

export interface CreateVMPayload {
  name: string
  vcpus: number
  memory_mb: number
  disk_gb: number
  os_iso?: string
  os: string
  network: string
}
