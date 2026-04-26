export interface Container {
  id: string
  name: string
  status: 'running' | 'stopped' | 'paused' | 'unknown'
  vcpus: number
  memory_mb: number
  disk_gb: number
  template: string
  ip?: string
}

export interface CreateContainerPayload {
  name: string
  template: string
  vcpus: number
  memory_mb: number
  disk_gb: number
  password: string
}
