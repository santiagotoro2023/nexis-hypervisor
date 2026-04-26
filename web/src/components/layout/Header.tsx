import { Bell, Wifi, AlertCircle } from 'lucide-react'
import { useMetrics } from '../../hooks/useMetrics'

export function Header({ title }: { title: string }) {
  const m = useMetrics()
  const critical = m.cpu_percent > 90 || m.memory_percent > 90

  return (
    <header className="h-12 flex items-center justify-between px-6 bg-nx-bg2 border-b border-nx-border shrink-0">
      <h1 className="text-xs font-semibold text-nx-fg tracking-[0.25em] uppercase">{title}</h1>
      <div className="flex items-center gap-5">
        <div className="flex items-center gap-1.5 text-[10px] text-nx-fg2 tracking-widest">
          <Wifi size={11} className="text-nx-green" />
          <span className="font-mono uppercase">{m.hostname}</span>
        </div>
        <div className="text-[10px] text-nx-fg2 font-mono tracking-wider flex items-center gap-3">
          <span>
            CPU{' '}
            <span className={m.cpu_percent > 80 ? 'text-nx-red' : 'text-nx-fg'}>
              {m.cpu_percent.toFixed(0)}%
            </span>
          </span>
          <span>
            MEM{' '}
            <span className={m.memory_percent > 85 ? 'text-nx-red' : 'text-nx-fg'}>
              {m.memory_percent.toFixed(0)}%
            </span>
          </span>
        </div>
        <button className={`transition-colors relative ${critical ? 'text-nx-red animate-pulse' : 'text-nx-fg2 hover:text-nx-fg'}`}>
          {critical ? <AlertCircle size={15} strokeWidth={1.8} /> : <Bell size={15} strokeWidth={1.8} />}
        </button>
      </div>
    </header>
  )
}
