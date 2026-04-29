import { useState } from 'react'
import { NxSpinner } from '../common/NxSpinner'

interface Props {
  onLogin: (username: string, password: string) => Promise<void>
  error: string | null
  loading: boolean
}

export function Login({ onLogin, error, loading }: Props) {
  const [username, setUsername] = useState('')
  const [pw, setPw] = useState('')

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    await onLogin(username, pw)
  }

  return (
    <div className="min-h-screen bg-nx-bg flex items-center justify-center p-4">
      <div className="fixed inset-0 pointer-events-none opacity-[0.03]"
        style={{ backgroundImage: 'linear-gradient(#C4B898 1px, transparent 1px), linear-gradient(90deg, #C4B898 1px, transparent 1px)', backgroundSize: '40px 40px' }} />

      <div className="w-full max-w-sm relative">
        <div className="text-center mb-10">
          <svg viewBox="0 0 56 56" fill="none" className="w-14 h-14 mx-auto mb-5">
            <path d="M28 5 L53 49 L3 49 Z" stroke="#F87200" strokeWidth="2" strokeLinejoin="round"/>
            <ellipse cx="28" cy="36" rx="9" ry="5.5" stroke="#F87200" strokeWidth="1.5" fill="none"/>
            <circle cx="28" cy="36" r="3" fill="#F87200"/>
            <circle cx="28" cy="36" r="1.3" fill="#080807"/>
          </svg>
          <div className="text-lg font-semibold text-nx-fg tracking-[0.4em] uppercase">NeXiS</div>
          <div className="text-nx-fg2 text-[10px] tracking-[0.5em] uppercase mt-1">Hypervisor Control System</div>
        </div>

        <div className="nx-card p-6 space-y-5">
          <div className="text-center">
            <div className="text-[10px] text-nx-fg2 tracking-[0.3em] uppercase">Identity Verification Required</div>
          </div>
          <form onSubmit={handleSubmit} className="space-y-4">
            <div>
              <label className="block text-[10px] text-nx-fg2 tracking-[0.25em] uppercase mb-1.5">Username</label>
              <input
                type="text"
                className="nx-input"
                placeholder="creator"
                value={username}
                onChange={e => setUsername(e.target.value)}
                autoFocus
                autoCapitalize="none"
                autoCorrect="off"
                spellCheck={false}
              />
            </div>
            <div>
              <label className="block text-[10px] text-nx-fg2 tracking-[0.25em] uppercase mb-1.5">Password</label>
              <input
                type="password"
                className="nx-input tracking-widest"
                placeholder="··········"
                value={pw}
                onChange={e => setPw(e.target.value)}
              />
            </div>
            {error && (
              <div className="text-nx-red text-[10px] tracking-wider text-center uppercase">
                {error.toLowerCase().includes('invalid') || error.toLowerCase().includes('401')
                  ? 'Access denied. Credentials not recognised.'
                  : error}
              </div>
            )}
            <button
              type="submit"
              className="nx-btn-primary w-full flex items-center justify-center gap-2 tracking-[0.2em] text-xs uppercase"
              disabled={loading || !username.trim() || !pw.trim()}
            >
              {loading && <NxSpinner size={14} />}
              {loading ? 'Verifying...' : 'Authenticate'}
            </button>
          </form>
        </div>

        <div className="text-center text-nx-fg2 text-[10px] mt-6 font-mono tracking-widest uppercase">
          Authorised Personnel Only · Local Access
        </div>
      </div>
    </div>
  )
}
