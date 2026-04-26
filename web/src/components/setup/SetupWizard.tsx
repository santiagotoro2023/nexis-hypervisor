import { useState } from 'react'
import { Check, ChevronRight, Shield, Server, Zap, Eye, EyeOff } from 'lucide-react'
import { NxSpinner } from '../common/NxSpinner'
import { api, setToken } from '../../api/client'

interface Props {
  onComplete: () => void
}

const STEPS = [
  { id: 'welcome',    label: 'INITIALISATION',   icon: Server },
  { id: 'password',   label: 'ACCESS CONTROL',    icon: Shield },
  { id: 'network',    label: 'NETWORK',           icon: Zap },
  { id: 'complete',   label: 'READY',             icon: Check },
]

export function SetupWizard({ onComplete }: Props) {
  const [step, setStep] = useState(0)
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [hostname, setHostname] = useState('')
  const [showPw, setShowPw] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  async function submitPassword() {
    if (password.length < 8) { setError('Access code must be at least 8 characters.'); return }
    if (password !== confirm) { setError('Access codes do not match.'); return }
    setError(null)
    setLoading(true)
    try {
      const { token } = await api.post<{ token: string }>('/auth/setup', { password })
      setToken(token)
      setStep(2)
    } catch (e) { setError((e as Error).message) }
    finally { setLoading(false) }
  }

  async function submitNetwork() {
    setLoading(true)
    try {
      if (hostname.trim()) await api.post('/system/hostname', { hostname: hostname.trim() })
      setStep(3)
    } catch { setStep(3) }
    finally { setLoading(false) }
  }

  async function finishSetup() {
    setLoading(true)
    try { await api.post('/auth/setup/complete') } catch { /* best-effort */ }
    finally { setLoading(false); onComplete() }
  }

  return (
    <div className="min-h-screen bg-nx-bg flex items-center justify-center p-4">
      <div
        className="fixed inset-0 pointer-events-none opacity-[0.03]"
        style={{ backgroundImage: 'linear-gradient(#C4B898 1px, transparent 1px), linear-gradient(90deg, #C4B898 1px, transparent 1px)', backgroundSize: '40px 40px' }}
      />

      <div className="w-full max-w-xl relative">
        {/* Header */}
        <div className="text-center mb-10">
          <svg viewBox="0 0 48 48" fill="none" className="w-10 h-10 mx-auto mb-5">
            <path d="M6 6h10l8 16 8-16h10L24 42 6 6z" fill="#F87200" />
          </svg>
          <div className="text-lg font-semibold text-nx-fg tracking-[0.4em] uppercase">Nexis</div>
          <div className="text-nx-fg2 text-[10px] tracking-[0.4em] uppercase mt-1">System Initialisation</div>
        </div>

        {/* Step indicator */}
        <div className="flex items-center justify-center gap-0 mb-8">
          {STEPS.map((s, i) => (
            <div key={s.id} className="flex items-center">
              <div className={`flex items-center gap-1.5 px-3 py-1.5 rounded text-[10px] tracking-widest uppercase transition-colors ${
                i === step
                  ? 'bg-nx-orange/10 text-nx-orange border border-nx-orange/30'
                  : i < step
                  ? 'text-nx-green'
                  : 'text-nx-fg2'
              }`}>
                {i < step ? <Check size={10} /> : <s.icon size={10} />}
                <span className="hidden sm:block">{s.label}</span>
              </div>
              {i < STEPS.length - 1 && (
                <ChevronRight size={12} className="text-nx-border mx-1" />
              )}
            </div>
          ))}
        </div>

        {/* Step content */}
        <div className="nx-card p-8 space-y-6">
          {step === 0 && (
            <div className="space-y-6">
              <div>
                <h2 className="text-sm font-semibold text-nx-fg tracking-[0.2em] uppercase">System Initialisation</h2>
                <p className="text-nx-fg2 text-xs mt-3 leading-relaxed">
                  This system has not been configured. Complete the following sequence to establish operational parameters.
                </p>
                <p className="text-nx-fg2 text-xs mt-2 leading-relaxed">
                  Access is restricted to authorised personnel. Configuration data is stored locally. No external network access is required.
                </p>
              </div>
              <div className="border border-nx-border rounded p-4 space-y-2">
                {[
                  'Establish administrator access credentials',
                  'Configure network identity',
                  'Verify system readiness',
                ].map((item, i) => (
                  <div key={i} className="flex items-center gap-3 text-xs text-nx-fg2">
                    <span className="text-nx-orange font-mono text-[10px]">0{i + 1}</span>
                    <span className="tracking-wider">{item}</span>
                  </div>
                ))}
              </div>
              <button className="nx-btn-primary w-full tracking-[0.2em] text-xs uppercase" onClick={() => setStep(1)}>
                Begin Initialisation
              </button>
            </div>
          )}

          {step === 1 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-sm font-semibold text-nx-fg tracking-[0.2em] uppercase">Access Control</h2>
                <p className="text-xs text-nx-fg2 mt-2">Establish the administrator access code for this system.</p>
              </div>
              <div className="space-y-4">
                <div>
                  <label className="block text-[10px] text-nx-fg2 tracking-widest uppercase mb-1.5">Access Code</label>
                  <div className="relative">
                    <input
                      type={showPw ? 'text' : 'password'}
                      className="nx-input pr-10"
                      placeholder="Minimum 8 characters"
                      value={password}
                      onChange={e => setPassword(e.target.value)}
                      autoFocus
                    />
                    <button
                      type="button"
                      className="absolute right-3 top-1/2 -translate-y-1/2 text-nx-fg2 hover:text-nx-fg"
                      onClick={() => setShowPw(v => !v)}
                    >
                      {showPw ? <EyeOff size={14} /> : <Eye size={14} />}
                    </button>
                  </div>
                </div>
                <div>
                  <label className="block text-[10px] text-nx-fg2 tracking-widest uppercase mb-1.5">Confirm Access Code</label>
                  <input
                    type={showPw ? 'text' : 'password'}
                    className="nx-input"
                    placeholder="Repeat access code"
                    value={confirm}
                    onChange={e => setConfirm(e.target.value)}
                    onKeyDown={e => { if (e.key === 'Enter') submitPassword() }}
                  />
                </div>
                {password.length > 0 && (
                  <div className="flex gap-1">
                    {[8, 12, 16, 20].map(n => (
                      <div
                        key={n}
                        className={`h-1 flex-1 rounded-full transition-colors ${
                          password.length >= n ? 'bg-nx-orange' : 'bg-nx-border'
                        }`}
                      />
                    ))}
                  </div>
                )}
              </div>
              {error && <div className="text-nx-red text-[10px] tracking-wider">{error}</div>}
              <button
                className="nx-btn-primary w-full tracking-[0.2em] text-xs uppercase flex items-center justify-center gap-2"
                onClick={submitPassword}
                disabled={loading || !password || !confirm}
              >
                {loading && <NxSpinner size={14} />}
                Set Access Code
              </button>
            </div>
          )}

          {step === 2 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-sm font-semibold text-nx-fg tracking-[0.2em] uppercase">Network Identity</h2>
                <p className="text-xs text-nx-fg2 mt-2">Configure the network hostname for this node. Leave blank to retain the current system hostname.</p>
              </div>
              <div>
                <label className="block text-[10px] text-nx-fg2 tracking-widest uppercase mb-1.5">Hostname (optional)</label>
                <input
                  className="nx-input font-mono"
                  placeholder="nexis-node-01"
                  value={hostname}
                  onChange={e => setHostname(e.target.value)}
                  onKeyDown={e => { if (e.key === 'Enter') submitNetwork() }}
                />
              </div>
              <div className="border border-nx-border rounded p-4 text-xs text-nx-fg2 space-y-1.5">
                <div className="text-[10px] text-nx-orange tracking-widest uppercase mb-2">Connectivity</div>
                <div>Web interface is accessible at <span className="text-nx-fg font-mono">https://&lt;this-host&gt;:8443</span></div>
                <div>TLS certificate is self-signed. Accept on first access.</div>
              </div>
              <div className="flex gap-3">
                <button className="nx-btn-ghost flex-1 tracking-wider text-xs" onClick={() => setStep(3)}>
                  Skip
                </button>
                <button
                  className="nx-btn-primary flex-1 tracking-[0.2em] text-xs uppercase flex items-center justify-center gap-2"
                  onClick={submitNetwork}
                  disabled={loading}
                >
                  {loading && <NxSpinner size={14} />}
                  Continue
                </button>
              </div>
            </div>
          )}

          {step === 3 && (
            <div className="space-y-6">
              <div className="text-center">
                <div className="w-12 h-12 rounded-full bg-nx-green/10 border border-nx-green/30 flex items-center justify-center mx-auto mb-4">
                  <Check size={20} className="text-nx-green" />
                </div>
                <h2 className="text-sm font-semibold text-nx-fg tracking-[0.2em] uppercase">System Ready</h2>
                <p className="text-xs text-nx-fg2 mt-2">Initialisation complete. All parameters are within acceptable ranges.</p>
              </div>
              <div className="border border-nx-border rounded p-4 text-xs space-y-2">
                {[
                  'Administrator credentials established',
                  'Network identity configured',
                  'Virtualisation layer online',
                  'Web interface secured',
                ].map((item, i) => (
                  <div key={i} className="flex items-center gap-3 text-nx-fg2">
                    <Check size={11} className="text-nx-green shrink-0" />
                    <span className="tracking-wider">{item}</span>
                  </div>
                ))}
              </div>
              <button
                className="nx-btn-primary w-full tracking-[0.2em] text-xs uppercase flex items-center justify-center gap-2"
                onClick={finishSetup}
                disabled={loading}
              >
                {loading && <NxSpinner size={14} />}
                Enter System
              </button>
            </div>
          )}
        </div>

        <div className="text-center text-[10px] text-nx-fg2 mt-6 tracking-widest uppercase font-mono">
          Nexis Hypervisor · Build 1.0.0 · Local Configuration
        </div>
      </div>
    </div>
  )
}
