import { Server, Box, HardDrive, Activity, Clock } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { NxGauge } from '../common/NxGauge'
import { useMetrics } from '../../hooks/useMetrics'

function formatUptime(seconds: number): string {
  const d = Math.floor(seconds / 86400)
  const h = Math.floor((seconds % 86400) / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  if (d > 0) return `${d}d ${h}h ${m}m`
  if (h > 0) return `${h}h ${m}m`
  return `${m}m`
}

function StatCard({ icon: Icon, label, value, sub, color = 'text-nx-orange' }: {
  icon: React.ElementType; label: string; value: string | number; sub?: string; color?: string
}) {
  return (
    <div className="nx-card p-5 flex items-start gap-4">
      <div className={`mt-0.5 ${color}`}>
        <Icon size={18} strokeWidth={1.5} />
      </div>
      <div>
        <div className="text-xl font-semibold text-nx-fg font-mono">{value}</div>
        <div className="text-[10px] text-nx-fg2 tracking-[0.2em] uppercase mt-0.5">{label}</div>
        {sub && <div className="text-[10px] text-nx-fg2 mt-1 font-mono">{sub}</div>}
      </div>
    </div>
  )
}

export function Dashboard() {
  const m = useMetrics()

  return (
    <AppLayout title="System Overview">
      <div className="space-y-6">
        {/* Host info strip */}
        <div className="nx-card px-5 py-4">
          <div className="flex flex-wrap items-center gap-x-8 gap-y-2">
            <div>
              <div className="text-[10px] text-nx-fg2 tracking-widest uppercase">Node</div>
              <div className="text-nx-fg font-medium font-mono mt-0.5 tracking-wider">{m.hostname.toUpperCase()}</div>
            </div>
            <div>
              <div className="text-[10px] text-nx-fg2 tracking-widest uppercase">Processor</div>
              <div className="text-nx-fg mt-0.5 text-xs font-mono max-w-xs truncate">{m.cpu_model}</div>
            </div>
            <div>
              <div className="text-[10px] text-nx-fg2 tracking-widest uppercase">Load</div>
              <div className="text-nx-fg font-mono mt-0.5 text-sm">
                {m.load_avg.map(l => l.toFixed(2)).join(' · ')}
              </div>
            </div>
            <div className="ml-auto flex items-center gap-1.5 text-nx-fg2">
              <Clock size={11} />
              <span className="text-[10px] font-mono tracking-wider">{formatUptime(m.uptime_seconds)}</span>
            </div>
          </div>
        </div>

        {/* Summary cards */}
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <StatCard
            icon={Server}
            label="Virtual Machines"
            value={m.vm_count}
            sub={`${m.vm_running} active`}
            color="text-nx-orange"
          />
          <StatCard
            icon={Box}
            label="Containers"
            value={m.container_count}
            sub={`${m.container_running} active`}
            color="text-nx-blue"
          />
          <StatCard
            icon={Activity}
            label="Inbound"
            value={`${m.net_recv_mbps.toFixed(1)} Mb/s`}
            color="text-nx-green"
          />
          <StatCard
            icon={HardDrive}
            label="Storage Used"
            value={`${m.disk_used_gb.toFixed(0)} GB`}
            sub={`of ${m.disk_total_gb.toFixed(0)} GB`}
            color="text-nx-yellow"
          />
        </div>

        {/* Resource gauges */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
          <div className="nx-card p-5">
            <NxGauge label="CPU Utilisation" value={m.cpu_percent} unit="%" percent={m.cpu_percent} />
          </div>
          <div className="nx-card p-5">
            <NxGauge label="Memory" value={m.memory_used_gb} max={m.memory_total_gb} unit=" GB" percent={m.memory_percent} />
          </div>
          <div className="nx-card p-5">
            <NxGauge label="Storage" value={m.disk_used_gb} max={m.disk_total_gb} unit=" GB" percent={m.disk_percent} />
          </div>
          <div className="nx-card p-5">
            <div className="flex flex-col gap-3">
              <div className="text-[10px] text-nx-fg2 tracking-widest uppercase">Network I/O</div>
              <div className="flex justify-between text-xs">
                <span className="text-nx-fg2 tracking-wider">↓ RECV</span>
                <span className="text-nx-green font-mono">{m.net_recv_mbps.toFixed(1)} Mb/s</span>
              </div>
              <div className="flex justify-between text-xs">
                <span className="text-nx-fg2 tracking-wider">↑ SEND</span>
                <span className="text-nx-orange font-mono">{m.net_sent_mbps.toFixed(1)} Mb/s</span>
              </div>
            </div>
          </div>
        </div>

        {/* Status line */}
        <div className="flex items-center gap-2 text-[10px] text-nx-fg2 tracking-widest uppercase">
          <span className="w-1.5 h-1.5 rounded-full bg-nx-green animate-pulse" />
          All systems nominal · Monitoring active
        </div>
      </div>
    </AppLayout>
  )
}
