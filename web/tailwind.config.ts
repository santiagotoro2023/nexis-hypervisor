import type { Config } from 'tailwindcss'

export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        nx: {
          bg: '#080807',
          bg2: '#0D0D0A',
          bg3: '#131310',
          dim: '#2A2A1A',
          orange: '#F87200',
          'orange-dim': '#C45C00',
          'orange-lit': '#FF9533',
          fg: '#C4B898',
          fg2: '#887766',
          border: '#1A1A12',
          outline: '#3A3A28',
          green: '#4CAF50',
          red: '#EF5350',
          yellow: '#FFC107',
          blue: '#2196F3',
        },
      },
      fontFamily: {
        mono: ['"JetBrains Mono"', '"Fira Code"', 'Consolas', 'monospace'],
      },
      animation: {
        'pulse-slow': 'pulse 3s cubic-bezier(0.4, 0, 0.6, 1) infinite',
      },
    },
  },
  plugins: [],
} satisfies Config
