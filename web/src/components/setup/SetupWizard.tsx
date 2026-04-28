import { useState } from 'react'
import { Check, ChevronRight, Link, Server, ArrowRight } from 'lucide-react'
import { NxSpinner } from '../common/NxSpinner'
import { api, setToken } from '../../api/client'

interface Props {
  onComplete: () => void
}

const STEPS = [
  { id: 'welcome', label: 'INITIALISATION', icon: Server },
  { id: 'connect', label: 'CONTROLLER',     icon: Link   },
  { id: 'ready',   label: 'READY',          icon: Check  },
]

export function SetupWizard({ onComplete }: Props) {
  const [step, setStep] = useState(0)
  const [url, setUrl] = useState('')
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  async function connect() {
    if (!url.trim())      { setError('Controller URL is required.'); return }
    if (!username.trim()) { setError('Username is required.'); return }
    if (!password)        { setError('Password is required.'); return }
    setError(null)
    setLoading(true)
    try {
      const { token } = await api.post<{ token: string }>('/auth/setup', {
        controller_url: url.trim(),
        username: username.trim(),
        password,
      })
      setToken(token)
      setStep(2)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setLoading(false) }
  }

  return (
    <div className="min-h-screen bg-nx-bg flex items-center justify-center p-4">
      <div
        className="fixed inset-0 pointer-events-none opacity-[0.03]"
        style={{ backgroundImage: 'linear-gradient(#C4B898 1px, transparent 1px), linear-gradient(90deg, #C4B898 1px, transparent 1px)', backgroundSize: '40px 40px' }}
      />

      <div className="w-full max-w-md relative">
        {/* Logo */}
        <div className="text-center mb-10">
          <svg viewBox="0 0 48 48" fill="none" className="w-10 h-10 mx-auto mb-5">
            <path d="M6 6h10l8 16 8-16h10L24 42 6 6z" fill="#F87200"/>
            <circle cx="24" cy="28" r="5" fill="#F87200" opacity="0.7"/>
            <circle cx="24" cy="28" r="2.5" fill="#080807"/>
          </svg>
          <div className="text-lg font-semibold text-nx-fg tracking-[0.4em] uppercase">NeXiS</div>
          <div className="text-nx-fg2 text-[10px] tracking-[0.4em] uppercase mt-1">Hypervisor Node</div>
        </div>

        {/* Step indicator */}
        <div className="flex items-center justify-center gap-0 mb-8">
          {STEPS.map((s, i) => (
            <div key={s.id} className="flex items-center">
              <div className={`flex items-center gap-1.5 px-3 py-1.5 rounded text-[10px] tracking-widest uppercase transition-colors ${
                i === step ? 'bg-nx-orange/10 text-nx-orange border border-nx-orange/30'
                  : i < step ? 'text-nx-green'
                  : 'text-nx-fg2'
              }`}>
                {i < step ? <Check size={10} /> : <s.icon size={10} />}
                <span className="hidden sm:block">{s.label}</span>
              </div>
              {i < STEPS.length - 1 && <ChevronRight size={12} className="text-nx-border mx-1" />}
            </div>
          ))}
        </div>

        <div className="nx-card p-8 space-y-6">

          {/* Step 0: Welcome */}
          {step === 0 && (
            <div className="space-y-6">
              <div>
                <h2 className="text-sm font-semibold text-nx-fg tracking-[0.2em] uppercase">Node Initialisation</h2>
                <p className="text-nx-fg2 text-xs mt-3 leading-relaxed">
                  This node has not been registered. Connect it to your NeXiS Controller to activate it.
                </p>
              </div>
              <div className="border border-nx-border rounded p-4 space-y-3">
                <div className="text-[10px] text-nx-orange tracking-widest uppercase mb-1">What happens next</div>
                {[
                  'Authenticate with your NeXiS Controller',
                  'This node registers itself with the Controller',
                  'All access is managed via Controller SSO',
                ].map((item, i) => (
                  <div key={i} className="flex items-start gap-3 text-xs text-nx-fg2">
                    <span className="text-nx-orange font-mono text-[10px] mt-0.5">0{i + 1}</span>
                    <span className="tracking-wider">{item}</span>
                  </div>
                ))}
              </div>
              <button className="nx-btn-primary w-full tracking-[0.2em] text-xs uppercase flex items-center justify-center gap-2" onClick={() => setStep(1)}>
                Begin <ArrowRight size={13} />
              </button>
            </div>
          )}

          {/* Step 1: Connect to Controller */}
          {step === 1 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-sm font-semibold text-nx-fg tracking-[0.2em] uppercase">Connect to Controller</h2>
                <p className="text-xs text-nx-fg2 mt-2">
                  Enter your NeXiS Controller URL and sign in with your NeXiS credentials.
                </p>
              </div>
              <div className="space-y-4">
                <div>
                  <label className="block text-[10px] text-nx-fg2 tracking-widest uppercase mb-1.5">Controller URL</label>
                  <input
                    className="nx-input font-mono"
                    placeholder="https://192.168.1.x:8443"
                    value={url}
                    onChange={e => setUrl(e.target.value)}
                    autoFocus
                    autoCapitalize="none"
                    spellCheck={false}
                  />
                </div>
                <div>
                  <label className="block text-[10px] text-nx-fg2 tracking-widest uppercase mb-1.5">Username</label>
                  <input
                    className="nx-input"
                    placeholder="your-username"
                    value={username}
                    onChange={e => setUsername(e.target.value)}
                    autoCapitalize="none"
                    spellCheck={false}
                  />
                </div>
                <div>
                  <label className="block text-[10px] text-nx-fg2 tracking-widest uppercase mb-1.5">Password</label>
                  <input
                    type="password"
                    className="nx-input"
                    placeholder="··········"
                    value={password}
                    onChange={e => setPassword(e.target.value)}
                    onKeyDown={e => { if (e.key === 'Enter') connect() }}
                  />
                </div>
              </div>
              {error && <div className="text-nx-red text-[10px] tracking-wider uppercase">{error}</div>}
              <button
                className="nx-btn-primary w-full tracking-[0.2em] text-xs uppercase flex items-center justify-center gap-2"
                onClick={connect}
                disabled={loading || !url.trim() || !username.trim() || !password}
              >
                {loading ? <><NxSpinner size={14} /> Connecting...</> : <>Connect <Link size={13} /></>}
              </button>
            </div>
          )}

          {/* Step 2: Done */}
          {step === 2 && (
            <div className="space-y-6">
              <div className="text-center">
                <div className="w-12 h-12 rounded-full bg-nx-green/10 border border-nx-green/30 flex items-center justify-center mx-auto mb-4">
                  <Check size={20} className="text-nx-green" />
                </div>
                <h2 className="text-sm font-semibold text-nx-fg tracking-[0.2em] uppercase">Node Registered</h2>
                <p className="text-xs text-nx-fg2 mt-2">This node is now connected to the NeXiS Controller. All access is managed centrally.</p>
              </div>
              <div className="border border-nx-border rounded p-4 text-xs space-y-2">
                {[
                  'Controller authentication established',
                  'Node registered in Controller dashboard',
                  'SSO active — Controller credentials accepted',
                  'Virtualisation layer online',
                ].map((item, i) => (
                  <div key={i} className="flex items-center gap-3 text-nx-fg2">
                    <Check size={11} className="text-nx-green shrink-0" />
                    <span className="tracking-wider">{item}</span>
                  </div>
                ))}
              </div>
              <button
                className="nx-btn-primary w-full tracking-[0.2em] text-xs uppercase"
                onClick={onComplete}
              >
                Enter System
              </button>
            </div>
          )}
        </div>

        <div className="text-center text-[10px] text-nx-fg2 mt-6 tracking-widest uppercase font-mono">
          NeXiS Hypervisor · Requires NeXiS Controller
        </div>
      </div>
    </div>
  )
}
