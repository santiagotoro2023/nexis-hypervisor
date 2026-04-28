import { NavLink } from 'react-router-dom'
import {
  LayoutDashboard, Server, Box, HardDrive, Network,
  LogOut, Zap, Activity, Settings,
} from 'lucide-react'
import { useAuth } from '../../hooks/useAuth'
import { useEffect, useState } from 'react'
import { api } from '../../api/client'

const NAV = [
  { to: '/',           icon: LayoutDashboard, label: 'SYSTEM OVERVIEW' },
  { to: '/vms',        icon: Server,          label: 'VIRTUAL INSTANCES' },
  { to: '/containers', icon: Box,             label: 'CONTAINERS' },
  { to: '/storage',    icon: HardDrive,       label: 'STORAGE' },
  { to: '/network',    icon: Network,         label: 'NETWORK' },
  { to: '/nexis',      icon: Zap,             label: 'CONTROLLER LINK' },
  { to: '/system',     icon: Settings,        label: 'SYSTEM' },
]

export function Sidebar() {
  const { logout } = useAuth()
  const [version, setVersion] = useState('—')

  useEffect(() => {
    api.get<{ version?: string }>('/system/info')
      .then(d => setVersion(d.version ?? '—'))
      .catch(() => {})
  }, [])

  return (
    <aside className="w-56 shrink-0 flex flex-col bg-nx-bg2 border-r border-nx-border h-screen sticky top-0">
      <div className="flex items-center gap-2.5 px-5 py-5 border-b border-nx-border">
        <div className="w-7 h-7 flex items-center justify-center">
          <svg viewBox="0 0 28 28" fill="none" className="w-7 h-7">
            <path d="M14 3 L26 23 L2 23 Z" stroke="#F87200" strokeWidth="1.5" strokeLinejoin="round"/>
            <ellipse cx="14" cy="17" rx="4.5" ry="2.8" stroke="#F87200" strokeWidth="1" fill="none"/>
            <circle cx="14" cy="17" r="1.4" fill="#F87200"/>
          </svg>
        </div>
        <div>
          <div className="text-nx-fg text-sm font-semibold tracking-[0.2em]">NEXIS</div>
          <div className="text-nx-fg2 text-[10px] tracking-[0.3em] uppercase">HYPERVISOR</div>
        </div>
      </div>

      <nav className="flex-1 py-3 px-2 flex flex-col gap-0.5 overflow-y-auto">
        {NAV.map(({ to, icon: Icon, label }) => (
          <NavLink
            key={to}
            to={to}
            end={to === '/'}
            className={({ isActive }) =>
              `flex items-center gap-3 px-3 py-2 rounded-xl text-xs tracking-widest transition-colors ${
                isActive
                  ? 'bg-nx-orange/10 text-nx-orange border border-nx-orange/20'
                  : 'text-nx-fg2 hover:text-nx-fg hover:bg-nx-dim'
              }`
            }
          >
            <Icon size={14} strokeWidth={1.5} />
            <span>{label}</span>
          </NavLink>
        ))}
      </nav>

      <div className="px-2 py-3 border-t border-nx-border">
        <button
          onClick={logout}
          className="flex items-center gap-3 px-3 py-2 w-full rounded-xl text-xs tracking-widest text-nx-fg2 hover:text-nx-red hover:bg-nx-red/5 transition-colors"
        >
          <LogOut size={14} strokeWidth={1.5} />
          <span>TERMINATE SESSION</span>
        </button>
        <div className="mt-2 px-3 flex items-center gap-1.5">
          <Activity size={10} className="text-nx-fg2" />
          <span className="text-nx-fg2 text-[10px] tracking-widest">NX-HV · BUILD {version}</span>
        </div>
      </div>
    </aside>
  )
}
