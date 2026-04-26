type Status = 'running' | 'stopped' | 'paused' | 'suspended' | 'crashed' | 'unknown'

const map: Record<Status, { cls: string; dot: string; label: string }> = {
  running:   { cls: 'nx-badge-running',  dot: 'bg-nx-green',  label: 'ACTIVE' },
  stopped:   { cls: 'nx-badge-stopped',  dot: 'bg-nx-red',    label: 'TERMINATED' },
  paused:    { cls: 'nx-badge-paused',   dot: 'bg-nx-yellow', label: 'SUSPENDED' },
  suspended: { cls: 'nx-badge-paused',   dot: 'bg-nx-yellow', label: 'SUSPENDED' },
  crashed:   { cls: 'nx-badge-stopped',  dot: 'bg-nx-red',    label: 'FAULTED' },
  unknown:   { cls: 'nx-badge-stopped',  dot: 'bg-nx-fg2',    label: 'UNKNOWN' },
}

export function StatusBadge({ status }: { status: string }) {
  const s = (map[status as Status] ?? map.unknown)
  return (
    <span className={s.cls}>
      <span className={`w-1.5 h-1.5 rounded-full ${s.dot} ${status === 'running' ? 'animate-pulse' : ''}`} />
      {s.label}
    </span>
  )
}
