import { useEffect, useRef } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { ChevronLeft } from 'lucide-react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import '@xterm/xterm/css/xterm.css'

export function ContainerShell() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const termRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!termRef.current || !id) return

    const term = new Terminal({
      fontFamily: '"JetBrains Mono", "Fira Code", monospace',
      fontSize: 13,
      theme: {
        background: '#080807',
        foreground: '#C4B898',
        cursor: '#F87200',
        selectionBackground: '#3A3A28',
        black: '#080807',
        red: '#EF5350',
        green: '#4CAF50',
        yellow: '#FFC107',
        blue: '#2196F3',
        magenta: '#CE93D8',
        cyan: '#4DD0E1',
        white: '#C4B898',
        brightBlack: '#2A2A1A',
        brightRed: '#FF5252',
        brightGreen: '#69F0AE',
        brightYellow: '#FFD740',
        brightBlue: '#40C4FF',
        brightMagenta: '#EA80FC',
        brightCyan: '#84FFFF',
        brightWhite: '#FFFFFF',
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
    const ws = new WebSocket(`${protocol}://${window.location.host}/api/containers/${id}/shell?token=${token}`)
    ws.binaryType = 'arraybuffer'

    ws.onopen = () => term.write('\x1b[1;33m[nexis]\x1b[0m Connected to container shell\r\n')
    ws.onmessage = (e) => term.write(new Uint8Array(e.data))
    ws.onclose = () => term.write('\r\n\x1b[1;31m[nexis]\x1b[0m Connection closed\r\n')

    term.onData(data => { if (ws.readyState === WebSocket.OPEN) ws.send(data) })
    term.onResize(({ cols, rows }) => {
      if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'resize', cols, rows }))
    })

    const resizeObserver = new ResizeObserver(() => fitAddon.fit())
    resizeObserver.observe(termRef.current)

    return () => {
      ws.close()
      term.dispose()
      resizeObserver.disconnect()
    }
  }, [id])

  return (
    <div className="flex flex-col h-screen bg-nx-bg">
      <div className="flex items-center gap-3 px-4 py-2 bg-nx-bg2 border-b border-nx-border shrink-0">
        <button onClick={() => navigate(`/containers/${id}`)} className="nx-btn-ghost flex items-center gap-1 text-xs">
          <ChevronLeft size={14} /> Back
        </button>
        <span className="text-xs text-nx-fg2 font-mono">Container Shell — {id}</span>
      </div>
      <div ref={termRef} className="flex-1" style={{ minHeight: 0, padding: '8px' }} />
    </div>
  )
}
