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
          <svg viewBox="0 0 48 48" fill="none" className="w-10 h-10 mx-auto mb-5">
            <path d="M6 6h10l8 16 8-16h10L24 42 6 6z" fill="#F87200"/>
            <circle cx="24" cy="28" r="5" fill="#F87200" opacity="0.7"/>
            <circle cx="24" cy="28" r="2.5" fill="#080807"/>
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
