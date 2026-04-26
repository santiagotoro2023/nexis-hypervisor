import { useState, useEffect } from 'react'
import { Zap, Link, Unlink, Send, CheckCircle, XCircle, RefreshCw } from 'lucide-react'
import { AppLayout } from '../layout/AppLayout'
import { NxSpinner } from '../common/NxSpinner'
import { api } from '../../api/client'

interface PairingStatus {
  paired: boolean
  controller_url?: string
  controller_name?: string
  last_ping?: string
  last_sync?: string
  status_feed_active: boolean
}

interface CommandResult {
  success: boolean
  response: string
  action_taken?: string
}

export function NexisController() {
  const [status, setStatus] = useState<PairingStatus | null>(null)
  const [loading, setLoading] = useState(true)
  const [url, setUrl] = useState('')
  const [password, setPassword] = useState('')
  const [pairing, setPairing] = useState(false)
  const [pairError, setPairError] = useState<string | null>(null)
  const [command, setCommand] = useState('')
  const [sending, setSending] = useState(false)
  const [cmdResult, setCmdResult] = useState<CommandResult | null>(null)
  const [history, setHistory] = useState<{ cmd: string; result: CommandResult; time: Date }[]>([])

  const fetchStatus = () =>
    api.get<PairingStatus>('/nexis/status').then(setStatus).finally(() => setLoading(false))

  useEffect(() => { fetchStatus() }, [])

  async function pair() {
    setPairing(true)
    setPairError(null)
    try {
      await api.post('/nexis/pair', { url: url.trim(), password })
      await fetchStatus()
      setPassword('')
    } catch (e) {
      setPairError((e as Error).message)
    } finally { setPairing(false) }
  }

  async function unpair() {
    if (!confirm('Disconnect from Nexis Controller?')) return
    await api.post('/nexis/unpair')
    fetchStatus()
  }

  async function sendCommand() {
    if (!command.trim() || !status?.paired) return
    setSending(true)
    setCmdResult(null)
    try {
      const result = await api.post<CommandResult>('/nexis/command', { command: command.trim() })
      setCmdResult(result)
      setHistory(h => [{ cmd: command, result, time: new Date() }, ...h.slice(0, 19)])
      setCommand('')
    } catch (e) {
      setCmdResult({ success: false, response: (e as Error).message })
    } finally { setSending(false) }
  }

  return (
    <AppLayout title="Nexis Controller">
      <div className="space-y-6 max-w-3xl">

        {/* Header */}
        <div className="nx-card p-5 flex items-start gap-4">
          <div className="mt-0.5 text-nx-orange">
            <Zap size={20} strokeWidth={1.5} />
          </div>
          <div>
            <h2 className="text-sm font-medium text-nx-fg">Controller Integration</h2>
            <p className="text-xs text-nx-fg2 mt-1">
              Connect this hypervisor to your Nexis Controller to enable voice commands, status feeds, and AI-driven VM management.
            </p>
          </div>
        </div>

        {loading ? (
          <div className="flex items-center justify-center py-20"><NxSpinner size={32} /></div>
        ) : !status?.paired ? (
          /* Pairing form */
          <div className="nx-card p-5 space-y-4">
            <h3 className="text-xs text-nx-fg2 uppercase tracking-wider flex items-center gap-2">
              <Link size={13} /> Pair with Controller
            </h3>
            <div>
              <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">Controller URL</label>
              <input
                className="nx-input"
                placeholder="https://192.168.1.10:8443"
                value={url}
                onChange={e => setUrl(e.target.value)}
              />
              <div className="text-xs text-nx-fg2 mt-1">The URL where your nexis-controller web UI is running</div>
            </div>
            <div>
              <label className="block text-xs text-nx-fg2 mb-1 uppercase tracking-wider">Controller Password</label>
              <input
                type="password"
                className="nx-input"
                placeholder="••••••••"
                value={password}
                onChange={e => setPassword(e.target.value)}
                onKeyDown={e => { if (e.key === 'Enter') pair() }}
              />
            </div>
            {pairError && <div className="text-nx-red text-xs">{pairError}</div>}
            <button
              className="nx-btn-primary flex items-center gap-2 w-full justify-center"
              onClick={pair}
              disabled={pairing || !url.trim() || !password.trim()}
            >
              {pairing ? <NxSpinner size={14} /> : <Link size={14} />}
              Connect to Controller
            </button>
          </div>
        ) : (
          /* Paired state */
          <>
            <div className="nx-card p-5 space-y-4">
              <div className="flex items-start justify-between">
                <h3 className="text-xs text-nx-fg2 uppercase tracking-wider flex items-center gap-2">
                  <CheckCircle size={13} className="text-nx-green" /> Connected
                </h3>
                <button className="nx-btn-ghost text-xs flex items-center gap-1.5" onClick={unpair}>
                  <Unlink size={12} /> Disconnect
                </button>
              </div>
              <div className="grid grid-cols-2 gap-4 text-xs">
                <div>
                  <div className="text-nx-fg2 uppercase tracking-wider mb-0.5">Controller</div>
                  <div className="text-nx-fg font-mono">{status.controller_name ?? status.controller_url}</div>
                </div>
                <div>
                  <div className="text-nx-fg2 uppercase tracking-wider mb-0.5">Status Feed</div>
                  <div className={status.status_feed_active ? 'text-nx-green' : 'text-nx-fg2'}>
                    {status.status_feed_active ? '● Active' : '○ Inactive'}
                  </div>
                </div>
                <div>
                  <div className="text-nx-fg2 uppercase tracking-wider mb-0.5">Last Ping</div>
                  <div className="text-nx-fg font-mono">{status.last_ping ? new Date(status.last_ping).toLocaleTimeString() : '—'}</div>
                </div>
                <div>
                  <div className="text-nx-fg2 uppercase tracking-wider mb-0.5">Last Sync</div>
                  <div className="text-nx-fg font-mono">{status.last_sync ? new Date(status.last_sync).toLocaleTimeString() : '—'}</div>
                </div>
              </div>
              <button className="nx-btn-ghost text-xs flex items-center gap-1.5" onClick={fetchStatus}>
                <RefreshCw size={12} /> Refresh Status
              </button>
            </div>

            {/* Command interface */}
            <div className="nx-card p-5 space-y-4">
              <h3 className="text-xs text-nx-fg2 uppercase tracking-wider">Send Command</h3>
              <p className="text-xs text-nx-fg2">Send a natural language command to the hypervisor via the controller's AI engine.</p>
              <div className="flex gap-2">
                <input
                  className="nx-input"
                  placeholder='e.g. "start my dev VM" or "take a snapshot of ubuntu-server"'
                  value={command}
                  onChange={e => setCommand(e.target.value)}
                  onKeyDown={e => { if (e.key === 'Enter') sendCommand() }}
                />
                <button
                  className="nx-btn-primary flex items-center gap-2 whitespace-nowrap"
                  onClick={sendCommand}
                  disabled={sending || !command.trim()}
                >
                  {sending ? <NxSpinner size={14} /> : <Send size={14} />}
                  Send
                </button>
              </div>
              {cmdResult && (
                <div className={`rounded p-3 text-xs font-mono ${cmdResult.success ? 'bg-nx-green/5 border border-nx-green/20 text-nx-green' : 'bg-nx-red/5 border border-nx-red/20 text-nx-red'}`}>
                  <div className="flex items-center gap-1.5 mb-1">
                    {cmdResult.success ? <CheckCircle size={12} /> : <XCircle size={12} />}
                    {cmdResult.action_taken ?? (cmdResult.success ? 'Success' : 'Failed')}
                  </div>
                  <div className="text-nx-fg whitespace-pre-wrap">{cmdResult.response}</div>
                </div>
              )}
            </div>

            {/* Command history */}
            {history.length > 0 && (
              <div className="nx-card overflow-hidden">
                <div className="px-5 py-3 border-b border-nx-border text-xs text-nx-fg2 uppercase tracking-wider">
                  Command History
                </div>
                <div className="divide-y divide-nx-border/50 max-h-72 overflow-y-auto">
                  {history.map((h, i) => (
                    <div key={i} className="px-5 py-3 text-xs">
                      <div className="flex items-center justify-between mb-1">
                        <span className="text-nx-fg font-mono">{h.cmd}</span>
                        <span className="text-nx-fg2">{h.time.toLocaleTimeString()}</span>
                      </div>
                      <div className={h.result.success ? 'text-nx-green' : 'text-nx-red'}>
                        {h.result.action_taken ?? h.result.response}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </>
        )}

        {/* Info box */}
        <div className="nx-card p-4 bg-nx-orange/5 border-nx-orange/20 text-xs text-nx-fg2 space-y-1.5">
          <div className="text-nx-orange font-medium text-xs uppercase tracking-wider">How it works</div>
          <ul className="space-y-1 list-disc list-inside">
            <li>This hypervisor registers as a device with your nexis-controller</li>
            <li>The controller receives real-time VM/resource status every 30 seconds</li>
            <li>You can say "Hey Nexis, start my dev VM" and it will route the command here</li>
            <li>The controller can also call hypervisor actions directly via its automation tools</li>
          </ul>
        </div>
      </div>
    </AppLayout>
  )
}
