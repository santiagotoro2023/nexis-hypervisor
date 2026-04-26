export function NxSpinner({ size = 16 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      className="animate-spin"
    >
      <circle cx="12" cy="12" r="10" stroke="#3A3A28" strokeWidth="3" />
      <path d="M12 2a10 10 0 0 1 10 10" stroke="#F87200" strokeWidth="3" strokeLinecap="round" />
    </svg>
  )
}
