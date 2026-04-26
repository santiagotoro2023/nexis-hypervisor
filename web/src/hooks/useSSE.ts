import { useEffect, useState, useRef } from 'react'
import { openSSE } from '../api/client'

export function useSSE<T>(path: string, initial: T) {
  const [data, setData] = useState<T>(initial)
  const esRef = useRef<EventSource | null>(null)

  useEffect(() => {
    const es = openSSE(path, (d) => setData(d as T))
    esRef.current = es
    return () => es.close()
  }, [path])

  return data
}
