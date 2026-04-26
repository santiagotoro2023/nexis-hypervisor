import { X } from 'lucide-react'
import { ReactNode, useEffect } from 'react'

interface Props {
  title: string
  onClose: () => void
  children: ReactNode
  width?: string
}

export function NxModal({ title, onClose, children, width = 'max-w-lg' }: Props) {
  useEffect(() => {
    const handler = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [onClose])

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4">
      <div className={`nx-card w-full ${width} shadow-2xl`}>
        <div className="flex items-center justify-between px-5 py-4 border-b border-nx-border">
          <h2 className="text-sm font-semibold text-nx-fg uppercase tracking-wider">{title}</h2>
          <button onClick={onClose} className="text-nx-fg2 hover:text-nx-fg transition-colors">
            <X size={16} />
          </button>
        </div>
        <div className="px-5 py-4">{children}</div>
      </div>
    </div>
  )
}
