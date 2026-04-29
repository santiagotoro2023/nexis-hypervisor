import { useState, useRef } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { ChevronLeft, Terminal, Wifi } from 'lucide-react'
import { Terminal as XTerm } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { NxSpinner } from '../common/NxSpinner'
import '@xterm/xterm/css/xterm.css'

export function NodeShell() {
  const { nodeId } = useParams<{ nodeId: string }>()
  const navigate = useNavigate()
  const termRef = useRef<HTMLDivElement>(null)
  const [phase, setPhase] = useState<'creds' | 'connecting' | 'connected'>('creds')
  const [user, setUser] = useState('root')
  const [password, setPassword] = useState('')
  const [port, setPort] = useState('22')
  const [error, setError] = useState<string | null>(null)

  function connect() {
    if (!termRef.current || !nodeId) return
    setError(null)
    setPhase('connecting')

    const term = new XTerm({
      fontFamily: '"JetBrains Mono", "Fira Code", monospace',
      fontSize: 13,
      theme: {
        background: '#080807',
        foreground: '#C4B898',
        cursor: '#F87200',
        selectionBackground: '#3A3A28',
        black: '#080807', red: '#EF5350', green: '#4CAF50', yellow: '#FFC107',
        blue: '#2196F3', magenta: '#CE93D8', cyan: '#4DD0E1', white: '#C4B898',
        brightBlack: '#2A2A1A', brightRed: '#FF5252', brightGreen: '#69F0AE',
        brightYellow: '#FFD740', brightBlue: '#40C4FF', brightMagenta: '#EA80FC',
        brightCyan: '#84FFFF', brightWhite: '#FFFFFF',
      },
      cursorBlink: true,
    })
    const fitAddon = new FitAddon()
    term.loadAddon(fitAddon)
    term.loadAddon(new WebLinksAddon())
    term.open(termRef.current)
    fitAddon.fit()

    const protocol = window.location.protocol === 'https:' ? 'wss' : 'ws'
    const token = sessionStorage.getItem('nx_token') ?? ''
    const ws = new WebSocket(
      `${protocol}://${window.location.host}/api/nodes/${nodeId}/shell?token=${token}`
    )
    ws.binaryType = 'arraybuffer'

    ws.onopen = () => {
      ws.send(JSON.stringify({
        user,
        password,
        port: parseInt(port) || 22,
        cols: term.cols,
        rows: term.rows,
      }))
      setPhase('connected')
    }

    ws.onmessage = (e) => {
      if (e.data instanceof ArrayBuffer) {
        term.write(new Uint8Array(e.data))
      } else {
        term.write(e.data)
      }
    }

    ws.onclose = () => term.write('\r\n\x1b[1;31m[nexis]\x1b[0m Connection closed\r\n')
    ws.onerror = () => {
      setError('WebSocket connection failed')
      setPhase('creds')
      term.dispose()
    }

    term.onData(data => { if (ws.readyState === WebSocket.OPEN) ws.send(data) })
    term.onResize(({ cols, rows }) => {
      if (ws.readyState === WebSocket.OPEN)
        ws.send(JSON.stringify({ type: 'resize', cols, rows }))
    })

    const ro = new ResizeObserver(() => fitAddon.fit())
    if (termRef.current) ro.observe(termRef.current)

    return () => { ws.close(); term.dispose(); ro.disconnect() }
  }

  return (
    <div className="flex flex-col h-screen bg-nx-bg">
      {/* Header */}
      <div className="flex items-center gap-3 px-4 py-2.5 bg-nx-bg2 border-b border-nx-border shrink-0">
        <button onClick={() => navigate(-1)} className="nx-btn-ghost flex items-center gap-1 text-xs">
          <ChevronLeft size={14} /> Back
        </button>
        <div className="flex items-center gap-2">
          <Terminal size={13} className="text-nx-orange" />
          <span className="text-xs text-nx-fg2 font-mono tracking-wider uppercase">
            Node Shell — {nodeId}
          </span>
        </div>
        {phase === 'connected' && (
          <div className="flex items-center gap-1.5 ml-auto">
            <Wifi size={11} className="text-nx-green" />
            <span className="text-[10px] text-nx-green tracking-widest uppercase">Connected</span>
          </div>
        )}
      </div>

      {/* Credentials overlay */}
      {phase === 'creds' && (
        <div className="flex-1 flex items-center justify-center bg-nx-bg">
          <div
            className="fixed inset-0 pointer-events-none opacity-[0.03]"
            style={{ backgroundImage: 'linear-gradient(#C4B898 1px, transparent 1px), linear-gradient(90deg, #C4B898 1px, transparent 1px)', backgroundSize: '40px 40px' }}
          />
          <div className="w-full max-w-sm relative">
            <div className="text-center mb-8">
              <svg viewBox="0 0 56 56" fill="none" className="w-12 h-12 mx-auto mb-4">
                <path d="M28 5 L53 49 L3 49 Z" stroke="#F87200" strokeWidth="2" strokeLinejoin="round"/>
                <ellipse cx="28" cy="36" rx="9" ry="5.5" stroke="#F87200" strokeWidth="1.5" fill="none"/>
                <circle cx="28" cy="36" r="3" fill="#F87200"/>
                <circle cx="28" cy="36" r="1.3" fill="#080807"/>
              </svg>
              <div className="text-sm font-semibold text-nx-fg tracking-[0.3em] uppercase">Node Shell</div>
              <div className="text-nx-fg2 text-[10px] tracking-[0.3em] uppercase mt-1">SSH Access</div>
            </div>
            <div className="nx-card p-6 space-y-4">
              <div className="text-[10px] text-nx-fg2 tracking-[0.25em] uppercase text-center">SSH Credentials</div>
              <div className="grid grid-cols-3 gap-3">
                <div className="col-span-2">
                  <label className="nx-label">Username</label>
                  <input className="nx-input" value={user} onChange={e => setUser(e.target.value)}
                    autoFocus autoCapitalize="none" spellCheck={false} />
                </div>
                <div>
                  <label className="nx-label">Port</label>
                  <input className="nx-input font-mono" value={port}
                    onChange={e => setPort(e.target.value)} />
                </div>
              </div>
              <div>
                <label className="nx-label">Password <span className="normal-case opacity-50">(leave blank for key auth)</span></label>
                <input type="password" className="nx-input tracking-widest"
                  placeholder="··········" value={password}
                  onChange={e => setPassword(e.target.value)}
                  onKeyDown={e => { if (e.key === 'Enter') connect() }} />
              </div>
              {error && <div className="text-nx-red text-[10px] tracking-wider uppercase">{error}</div>}
              <button className="nx-btn-primary w-full flex items-center justify-center gap-2 tracking-[0.2em] text-xs uppercase"
                onClick={connect}>
                <Terminal size={13} /> Open Shell
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Connecting overlay */}
      {phase === 'connecting' && (
        <div className="flex-1 flex items-center justify-center">
          <div className="flex items-center gap-3 text-nx-fg2">
            <NxSpinner size={18} />
            <span className="text-xs tracking-widest uppercase">Establishing SSH connection...</span>
          </div>
        </div>
      )}

      {/* Terminal */}
      <div
        ref={termRef}
        className="flex-1"
        style={{ minHeight: 0, padding: '8px', display: phase === 'connected' ? 'block' : 'none' }}
      />
    </div>
  )
}
