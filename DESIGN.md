# NeXiS Design System

Shared visual language for all NeXiS interfaces (web, Android, desktop). Every surface in the ecosystem follows these tokens. The NeXiS Hypervisor web UI is the reference implementation.

---

## Colour Tokens

| Token | Hex | Usage |
|-------|-----|-------|
| `bg` | `#080807` | Page / root background |
| `bg2` | `#0D0D0A` | Sidebar, header, panel backgrounds |
| `bg3` | `#131310` | Cards, modals, elevated surfaces |
| `dim` | `#2A2A1A` | Hover states, subtle fills |
| `orange` | `#F87200` | Primary accent — interactive elements, active states, logo |
| `orange-dim` | `#C45C00` | Muted primary — secondary buttons, icons at rest |
| `orange-lit` | `#FF9533` | Hover state for orange elements |
| `fg` | `#C4B898` | Body text, data values |
| `fg2` | `#887766` | Secondary text, labels, placeholders |
| `border` | `#1A1A12` | Dividers and card outlines |
| `outline` | `#3A3A28` | Scrollbars, focus rings |
| `green` | `#4CAF50` | Status: running / active / nominal |
| `red` | `#EF5350` | Status: stopped / error / critical |
| `yellow` | `#FFC107` | Status: warning / paused / degraded |
| `blue` | `#2196F3` | Status: informational |

---

## Typography

**Primary font:** JetBrains Mono → Fira Code → Consolas → monospace  
Everything is monospaced. Proportional fonts are not used in the NeXiS UI.

| Role | Size | Weight | Transform | Letter spacing |
|------|------|--------|-----------|---------------|
| Page title | 12px | 600 | uppercase | 0.25em |
| Section label | 10px | 400 | uppercase | 0.3em |
| Body / data | 12px | 400 | none | 0.05em |
| Status / badge | 10px | 500 | uppercase | 0.2em |
| Large value | 20–24px | 600 | none | default |

---

## Component Language

**Cards:** `bg3` background · `border` colour border · no border-radius or 4px max  
**Buttons:**  
- Primary: `orange` background · `bg` text  
- Ghost: transparent · `orange` text · `orange/10` hover fill  
- Danger: `red/10` background · `red` text  

**Status dots:** 8px circle — `green` active · `red` inactive · `dim` unknown  
**Inputs:** `bg` fill · `outline` border · `orange` focus ring  
**Navigation active state:** `orange/10` fill · `orange` text · `orange/20` border

---

## Motion

- Transitions: `150ms ease` for colour/opacity changes
- Loading pulse: 3 s `cubic-bezier(0.4, 0, 0.6, 1)` opacity oscillation
- No decorative animation; motion serves only state communication

---

## Voice and Tone

- All labels uppercase
- No marketing language; describe function precisely
- System state is reported, not narrated — "INACTIVE" not "Service is not running"
- Actions are direct — "TERMINATE SESSION", "INITIALISING SYSTEM", "AWAITING INPUT"
- Errors state the condition, not an apology
