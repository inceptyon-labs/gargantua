# Gargantua Design System

**Product:** Native macOS system cleaner for developers  
**Theme:** Dark mode primary — developer tool aesthetic  
**Metaphor:** Deep space, gravitational pull, the event horizon from Interstellar

---

## Intent

**Who:** Developer Mac owner — Homebrew, Docker, Node.js, Xcode. Between coding sessions. Scrutinizes what's being deleted. Trusts open source, hates subscriptions.

**What they must do:** Scan, review classified items, make trusted deletion decisions. The verb is *decide* — not "clean," *decide what to trust.*

**How it should feel:** A terminal that grew up. Cold like space. Precise like a file path. Dense like a trading floor but not chaotic. Safety signals warm and clear against the void.

---

## Color Palette

### Primitives (CSS custom properties)

```css
/* Surfaces — same hue, shifting lightness only */
--void:        hsl(220, 14%, 9%);    /* Canvas / page background */
--surface-1:   hsl(220, 12%, 11%);   /* Sidebar, panels */
--surface-2:   hsl(220, 11%, 14%);   /* Cards, list rows */
--surface-3:   hsl(220, 10%, 17%);   /* Dropdowns, elevated cards */
--surface-4:   hsl(220, 10%, 20%);   /* Tooltips, topmost layer */

/* Text hierarchy */
--ink:         hsl(210, 20%, 94%);   /* Primary — star-white, slightly warm */
--ink-2:       hsl(215, 12%, 65%);   /* Secondary — dim star gray */
--ink-3:       hsl(218, 10%, 45%);   /* Tertiary — nebula muted */
--ink-4:       hsl(220, 8%, 30%);    /* Muted — disabled, placeholder */

/* Borders */
--border:      rgba(255, 255, 255, 0.07);   /* Standard separation */
--border-soft: rgba(255, 255, 255, 0.04);   /* Subtle separation */
--border-em:   rgba(255, 255, 255, 0.13);   /* Emphasis */
--border-focus: hsl(213, 90%, 55%);         /* Focus ring — Hawking blue */

/* Safety classification (Trust Layer) */
--safe:       hsl(148, 45%, 42%);    /* Confirmed safe — desaturated terminal green */
--safe-dim:   hsla(148, 45%, 42%, 0.12);  /* Safe background tint */
--review:     hsl(38, 85%, 52%);     /* Needs review — accretion disc amber */
--review-dim: hsla(38, 85%, 52%, 0.12);  /* Review background tint */
--protected:  hsl(0, 62%, 48%);      /* Protected — deep red ember */
--protected-dim: hsla(0, 62%, 48%, 0.12); /* Protected background tint */

/* Interactive accent — distinct from safety palette */
--accent:     hsl(213, 90%, 55%);    /* Hawking radiation blue — buttons, links, focus */
--accent-dim: hsla(213, 90%, 55%, 0.12);

/* Semantic */
--success:    var(--safe);
--warning:    var(--review);
--destructive: var(--protected);
```

### Named token reference

| Token | Value | Use |
|-------|-------|-----|
| `--void` | 9% lightness | Page canvas |
| `--surface-1` | 11% | Sidebar, secondary panels |
| `--surface-2` | 14% | Cards, list items |
| `--surface-3` | 17% | Dropdowns, popovers |
| `--surface-4` | 20% | Tooltips |
| `--ink` | 94% | Primary text |
| `--ink-2` | 65% | Supporting text |
| `--ink-3` | 45% | Metadata |
| `--ink-4` | 30% | Disabled, placeholder |
| `--accent` | Cold blue | Interactive elements |
| `--safe` | Terminal green | Safe classification |
| `--review` | Amber gold | Review classification |
| `--protected` | Red ember | Protected classification |

---

## Typography

```css
/* System stack — macOS native feel */
--font-ui: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", system-ui, sans-serif;

/* Monospace — file paths, sizes, confidence, code */
--font-mono: "SF Mono", "JetBrains Mono", "Fira Code", Menlo, monospace;
--font-feature-settings: "tnum" 1;  /* Tabular numbers — required for sizes/percentages */
```

### Scale

| Level | Size | Weight | Tracking | Use |
|-------|------|--------|----------|-----|
| Display | 28px | 700 | -0.04em | Scan total, hero numbers |
| Heading | 16px | 600 | -0.02em | Section headers |
| Label | 13px | 500 | 0 | List item names |
| Body | 13px | 400 | 0 | Descriptions, explanations |
| Caption | 11px | 400 | 0.01em | Metadata, timestamps |
| Mono-data | 12px mono | 400 | 0 | File sizes, paths, confidence % |
| Mono-path | 11px mono | 400 | 0 | File paths (truncated with ellipsis) |

---

## Depth Strategy: Borders Only

No shadows. In space there are no point-light sources.

- Surface elevation: lightness steps (9% → 11% → 14% → 17% → 20%)
- Section separation: `var(--border)` — `rgba(255,255,255, 0.07)`
- Sidebar: same `--void` background as canvas, separated by single `--border` line
- Inputs: `--surface-3` background (slightly darker than surroundings, "inset" feel)
- Dropdowns: `--surface-3`, elevated above `--surface-2` card context
- Focus rings: `--border-focus` (accent blue), 2px, 2px offset

---

## Spacing

Base unit: **4px**

| Name | Value | Use |
|------|-------|-----|
| `--space-1` | 4px | Icon gaps, tight pairs |
| `--space-2` | 8px | Inline spacing within components |
| `--space-3` | 12px | Compact component padding |
| `--space-4` | 16px | Standard component padding |
| `--space-5` | 24px | Between related groups |
| `--space-6` | 32px | Between distinct sections |
| `--space-7` | 48px | Major layout separation |
| `--space-8` | 64px | Page-level breathing room |

---

## Border Radius

Technical precision — sharp enough to feel like a tool.

| Context | Value |
|---------|-------|
| Inputs, buttons, badges | 4px |
| Cards, list containers | 6px |
| Modals, sheets | 8px |
| Tooltips | 4px |
| Circular / orbit rings | 50% |

---

## Signature: Confidence Orbit

The gravitational confidence indicator — a thin circular arc that completes as certainty increases. Used on scan items to show confidence percentage (from the Trust Layer).

Inspired by Gargantua's orbital rings in Interstellar.

- Track: `--border` (barely visible ring)
- Fill: Colored by safety level (`--safe`, `--review`, `--protected`)
- Size: 24×24px at item row density
- Accompanied by the percentage in `--font-mono` at 10px

This replaces progress bars and percentage badges. It's specific to this product.

---

## Safety Classification Display

```
🟢 Safe     → --safe color, --safe-dim background tint
🟡 Review   → --review color, --review-dim background tint
🔴 Protected → --protected color, --protected-dim background tint
```

Classification marks appear as a left-border accent on list items (3px colored bar), not as badge pills.

The left-border + background tint communicates classification immediately at scan without requiring text labels — labels supplement, they don't carry the signal.

---

## Navigation

- Sidebar: `--void` background (not `--surface-1`), separated by `var(--border)` right border
- Sidebar width: 200px
- Active item: `--surface-2` background + `--accent` left indicator bar (2px)
- Hover: `--surface-1` background
- Section labels: `--ink-4`, 10px, 600 weight, uppercase, 0.08em tracking

---

## Animation

- Micro-interactions: 100–150ms, ease-out
- Panel transitions: 200ms, ease-out
- Scan progress: 300ms per update, linear
- No bounce or spring easing — this is a precision tool

---

## Key Component Patterns

### Scan Result Item
- Container: `--surface-2` background, 6px radius
- Left border: 3px, colored by safety level
- Background tint: safety-dim color at full opacity
- Layout: flex row — confidence orbit | name + explanation | size | action
- File paths: `--font-mono`, `--ink-3`, 11px, truncated
- Size: `--font-mono`, `--ink`, tabular numbers, right-aligned

### Safety Badge (when explicit label needed)
- No pill. Text only: safety level name in its color, 11px, 600 weight
- Never background-filled independently — the row tint provides context

### Confirmation Dialog
- Modal with `--surface-3` background
- List of affected items with classification marks
- Destructive action button: `--protected` background, white text
- Cancel: ghost button (border only, `--border-em`)

---

## What to Avoid

- Gradients (unmotivated color is noise)
- Multiple accent colors (the safety palette is already 3 colors — accent stays cold blue only)
- Shadows (borders only)
- Pure black (`#000000`) — use `--void`
- Light mode until explicitly designed
- Playful radius on technical components
- Animated decorative elements

---

*Established: April 14, 2026*  
*Direction: Space-cold terminal, Interstellar metaphor, Trust Layer as primary design driver*
