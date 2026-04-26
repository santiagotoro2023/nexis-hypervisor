interface Props {
  label: string
  value: number
  max?: number
  unit?: string
  percent?: number
  color?: string
}

export function NxGauge({ label, value, max, unit = '', percent, color = '#F87200' }: Props) {
  const pct = percent ?? (max ? Math.round((value / max) * 100) : 0)
  const danger = pct > 85
  const warn = pct > 65

  const barColor = danger ? '#EF5350' : warn ? '#FFC107' : color

  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-baseline justify-between text-xs">
        <span className="text-nx-fg2 uppercase tracking-widest">{label}</span>
        <span className="text-nx-fg font-medium">
          {value.toFixed(1)}{unit}
          {max !== undefined && <span className="text-nx-fg2"> / {max.toFixed(1)}{unit}</span>}
        </span>
      </div>
      <div className="h-1.5 bg-nx-border rounded-full overflow-hidden">
        <div
          className="h-full rounded-full transition-all duration-700"
          style={{ width: `${Math.min(pct, 100)}%`, backgroundColor: barColor }}
        />
      </div>
      <div className="text-xs text-nx-fg2 text-right">{pct}%</div>
    </div>
  )
}
