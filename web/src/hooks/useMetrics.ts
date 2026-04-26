import { useSSE } from './useSSE'

export interface HostMetrics {
  cpu_percent: number
  memory_used_gb: number
  memory_total_gb: number
  memory_percent: number
  disk_used_gb: number
  disk_total_gb: number
  disk_percent: number
  net_sent_mbps: number
  net_recv_mbps: number
  uptime_seconds: number
  hostname: string
  cpu_model: string
  vm_count: number
  container_count: number
  vm_running: number
  container_running: number
  load_avg: [number, number, number]
}

const INITIAL: HostMetrics = {
  cpu_percent: 0,
  memory_used_gb: 0,
  memory_total_gb: 0,
  memory_percent: 0,
  disk_used_gb: 0,
  disk_total_gb: 0,
  disk_percent: 0,
  net_sent_mbps: 0,
  net_recv_mbps: 0,
  uptime_seconds: 0,
  hostname: '...',
  cpu_model: '...',
  vm_count: 0,
  container_count: 0,
  vm_running: 0,
  container_running: 0,
  load_avg: [0, 0, 0],
}

export function useMetrics() {
  return useSSE<HostMetrics>('/metrics/stream', INITIAL)
}
