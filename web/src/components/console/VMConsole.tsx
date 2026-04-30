import { useEffect, useRef, useState, useCallback } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { ChevronLeft, Clipboard, ClipboardPaste, Maximize2, Power } from 'lucide-react'

export function VMConsole() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const containerRef = useRef<HTMLDivElement>(null)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const rfbRef = useRef<any>(null)
  const [connected, setConnected] = useState(false)
  const [clipText, setClipText] = useState('')
  const [showClip, setShowClip] = useState(false)

  const sendClipboard = useCallback(() => {
    if (rfbRef.current && clipText) {
      rfbRef.current.clipboardPasteFrom(clipText)
    }
  }, [clipText])

  const readClipboard = useCallback(async () => {
    try {
      const text = await navigator.clipboard.readText()
      setClipText(text)
      if (rfbRef.current) rfbRef.current.clipboardPasteFrom(text)
    } catch {
      setShowClip(true)
    }
  }, [])

  useEffect(() => {
    if (!containerRef.current || !id) return

    const token = sessionStorage.getItem('nx_token') ?? ''
    const protocol = window.location.protocol === 'https:' ? 'wss' : 'ws'
    const wsUrl = `${protocol}://${window.location.host}/api/vms/${id}/console?token=${token}`

    let rfb: unknown
    const script = document.createElement('script')
    script.src = '/novnc/core/rfb.js'
    script.type = 'module'

    script.onload = () => {
      if (!containerRef.current) return
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const RFB = (window as any).RFB
      if (!RFB) return

      rfb = new RFB(containerRef.current, wsUrl)
      rfbRef.current = rfb

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const r = rfb as any
      r.viewOnly = false
      r.scaleViewport = true
      r.resizeSession = true

      r.addEventListener('connect', () => setConnected(true))
      r.addEventListener('disconnect', () => setConnected(false))

      // Sync clipboard from VM → browser
      r.addEventListener('clipboard', (e: { detail: { text: string } }) => {
        navigator.clipboard.writeText(e.detail.text).catch(() => {
          setClipText(e.detail.text)
          setShowClip(true)
        })
      })
    }

    document.head.appendChild(script)

    // Keyboard shortcut: Ctrl+Alt+V pastes clipboard into VM
    const handleKey = (e: KeyboardEvent) => {
      if (e.ctrlKey && e.altKey && e.key === 'v') {
        e.preventDefault()
        readClipboard()
      }
    }
    window.addEventListener('keydown', handleKey)

    return () => {
      document.head.removeChild(script)
      window.removeEventListener('keydown', handleKey)
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      if (rfbRef.current) (rfbRef.current as any).disconnect?.()
    }
  }, [id, readClipboard])

  return (
    <div className="flex flex-col h-screen bg-black">
      {/* Toolbar */}
      <div className="flex items-center gap-3 px-4 py-2 bg-nx-bg2 border-b border-nx-border shrink-0">
        <button
          onClick={() => navigate(`/vms/${id}`)}
          className="nx-btn-ghost flex items-center gap-1 text-[10px] tracking-widest uppercase"
        >
          <ChevronLeft size={13} /> Back
        </button>

        <div className="h-4 w-px bg-nx-border" />

        <span className="text-[10px] text-nx-fg2 font-mono tracking-widest uppercase">
          Console · {id}
        </span>

        <div className="flex items-center gap-1.5 ml-2">
          <span className={`w-1.5 h-1.5 rounded-full ${connected ? 'bg-nx-green animate-pulse' : 'bg-nx-red'}`} />
          <span className="text-[10px] text-nx-fg2 tracking-widest uppercase">
            {connected ? 'Connected' : 'Connecting...'}
          </span>
        </div>

        <div className="ml-auto flex items-center gap-2">
          {/* Paste clipboard into VM */}
          <button
            title="Paste clipboard into VM (Ctrl+Alt+V)"
            className="nx-btn-ghost flex items-center gap-1.5 text-[10px] tracking-widest uppercase"
            onClick={readClipboard}
          >
            <ClipboardPaste size={13} /> Paste
          </button>

          {/* Fullscreen */}
          <button
            title="Fullscreen"
            className="nx-btn-ghost flex items-center gap-1.5 text-[10px] tracking-widest uppercase"
            onClick={() => containerRef.current?.requestFullscreen?.()}
          >
            <Maximize2 size={13} /> Fullscreen
          </button>

          {/* Send Ctrl+Alt+Del */}
          <button
            title="Send Ctrl+Alt+Del"
            className="nx-btn-ghost flex items-center gap-1.5 text-[10px] tracking-widest uppercase text-nx-fg2 hover:text-nx-red"
            onClick={() => rfbRef.current?.sendCtrlAltDel?.()}
          >
            <Power size={13} /> Ctrl+Alt+Del
          </button>
        </div>
      </div>

      {/* Console viewport */}
      <div ref={containerRef} className="flex-1 bg-black" style={{ minHeight: 0 }} />

      {/* Clipboard fallback overlay */}
      {showClip && (
        <div className="absolute bottom-16 right-4 w-80 nx-card p-4 space-y-3 shadow-2xl">
          <div className="flex items-center gap-2">
            <Clipboard size={13} className="text-nx-orange" />
            <span className="text-[10px] text-nx-fg2 tracking-widest uppercase">Clipboard Relay</span>
          </div>
          <textarea
            className="nx-input text-xs font-mono h-24 resize-none"
            placeholder="Paste text here to send to the instance..."
            value={clipText}
            onChange={e => setClipText(e.target.value)}
          />
          <div className="flex gap-2 justify-end">
            <button className="nx-btn-ghost text-xs" onClick={() => setShowClip(false)}>Dismiss</button>
            <button
              className="nx-btn-primary text-xs tracking-wider"
              onClick={() => { sendClipboard(); setShowClip(false) }}
            >
              Send to VM
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
