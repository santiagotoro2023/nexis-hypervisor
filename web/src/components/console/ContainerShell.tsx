import { useEffect, useRef, useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { ChevronLeft, RefreshCw } from 'lucide-react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import '@xterm/xterm/css/xterm.css'

export function ContainerShell() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const termRef = useRef<HTMLDivElement>(null)
  const [status, setStatus] = useState<'connecting' | 'connected' | 'disconnected'>('connecting')
  const reconnectRef = useRef<(() => void) | null>(null)

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

    // Defer fit() until after the element is rendered
    requestAnimationFrame(() => fitAddon.fit())

    const protocol = window.location.protocol === 'https:' ? 'wss' : 'ws'
    const token = sessionStorage.getItem('nx_token') ?? ''
    const wsUrl = `${protocol}://${window.location.host}/api/containers/${encodeURIComponent(id)}/shell?token=${encodeURIComponent(token)}`

    let ws: WebSocket
    let closed = false

    function connect() {
      if (closed) return
      ws = new WebSocket(wsUrl)
      ws.binaryType = 'arraybuffer'

      ws.onopen = () => {
        setStatus('connected')
        term.write('\x1b[1;33m[nexis]\x1b[0m Connected to container shell\r\n')
        // Send initial terminal size
        const msg = JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows })
        ws.send(msg)
      }

      ws.onmessage = (e) => {
        if (e.data instanceof ArrayBuffer) {
          term.write(new Uint8Array(e.data))
        } else if (typeof e.data === 'string') {
          term.write(e.data)
        }
      }

      ws.onclose = () => {
        if (!closed) {
          setStatus('disconnected')
          term.write('\r\n\x1b[1;31m[nexis]\x1b[0m Connection closed\r\n')
        }
      }

      ws.onerror = () => {
        term.write('\r\n\x1b[1;31m[nexis]\x1b[0m WebSocket error\r\n')
      }
    }

    connect()
    reconnectRef.current = connect

    // Send keypresses as binary for proper encoding
    const dataDisposable = term.onData(data => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        // Send as binary ArrayBuffer for reliable PTY passthrough
        const encoded = new TextEncoder().encode(data)
        ws.send(encoded.buffer)
      }
    })

    const resizeDisposable = term.onResize(({ cols, rows }) => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'resize', cols, rows }))
      }
    })

    const resizeObserver = new ResizeObserver(() => fitAddon.fit())
    resizeObserver.observe(termRef.current!)

    return () => {
      closed = true
      dataDisposable.dispose()
      resizeDisposable.dispose()
      ws?.close()
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
        <div className="ml-auto flex items-center gap-2">
          <span className={`w-1.5 h-1.5 rounded-full ${
            status === 'connected' ? 'bg-nx-green animate-pulse' :
            status === 'disconnected' ? 'bg-nx-red' : 'bg-nx-yellow animate-pulse'
          }`} />
          <span className="text-[10px] text-nx-fg2 tracking-widest uppercase">{status}</span>
          {status === 'disconnected' && (
            <button
              className="nx-btn-ghost flex items-center gap-1 text-xs"
              onClick={() => reconnectRef.current?.()}
            >
              <RefreshCw size={12} /> Reconnect
            </button>
          )}
        </div>
      </div>
      <div ref={termRef} className="flex-1" style={{ minHeight: 0 }} />
    </div>
  )
}
