# Design Language — jacobitosuperstar.github.io

A reference for the visual and structural decisions behind this personal
portfolio site.

---

## Philosophy

**Hard-edged.** No border-radius anywhere. Every corner is a right angle. Sharp
geometry is a deliberate choice, not an oversight.

**Colombian.** The decorative vocabulary comes from specific cultural sources —
Wayuu mochila bag geometry, vueltiao hat weave structure, Muisca gold work,
Wiphala colour diagonal — treated not as surface ornament but as underlying
geometric logic for patterns, shadows, and colour rhythm.

**Monospace.** One font for everything: headings, body copy, code blocks, UI
labels. Fira Code variable font, self-hosted.

**Lean.** No external requests. No CDN. No CSS framework. Self-hosted fonts
only.

---

## Technology Stack

- Hugo static site generator, multilingual (ES / EN)
- Custom CSS only
- Single self-hosted variable font (woff2)

---

## Colour

### Base

| Role                 | Value                   |
| -------------------- | ----------------------- |
| Background           | `#000` black            |
| Body text / headings | `whitesmoke`            |
| Primary accent       | `#fa8072` salmon        |
| Secondary accent     | `#eee8aa` palegoldenrod |

### Colombian Palette Candidates

These are colour sets derived from Colombian cultural references, available for
future use or theme variants.

**Wiphala diagonal**

| Name     | Hex       |
| -------- | --------- |
| Rojo     | `#c0392b` |
| Naranja  | `#e67e22` |
| Amarillo | `#e8c44a` |
| Verde    | `#27ae60` |
| Azul     | `#2980b9` |
| Violeta  | `#8e44ad` |

**Muisca / pre-Columbian metalwork**

| Name      | Hex       |
| --------- | --------- |
| Oro viejo | `#c9952a` |
| Cobre     | `#b5541a` |
| Tumbaga   | `#d4901a` |
| Esmeralda | `#1a7a4a` |

### Light / Dark Theming

All colour is expressed as CSS custom properties on `:root` using
`light-dark(light, dark)`. `color-scheme: light dark` follows the OS
preference; the navbar toggle (☾ / ☀) forces a mode by setting
`data-theme` on `<html>`, persisted in `localStorage` and restored by a
pre-paint script in `head.html`.

Dark values are the original palette. Light values are drawn from the
Colombian palette candidates above.

| Token          | Light                | Dark                |
| -------------- | -------------------- | ------------------- |
| `--bg`         | `#f7f5f0` off-white  | `#000` black        |
| `--text`       | `#111`               | `whitesmoke`        |
| `--text-muted` | `#666`               | `#888`              |
| `--accent`     | `salmon`             | `salmon`            |
| `--accent-2`   | `#c9952a` oro viejo  | `palegoldenrod`     |
| `--accent-hot` | `#c0392b` rojo       | `red`               |
| `--link-soft`  | `#b5541a` cobre      | `pink`              |
| `--hover-warm` | `#c0392b` rojo       | `orange`            |
| `--icon`       | `#1a7a4a` esmeralda  | `mediumspringgreen` |
| `--icon-hover` | `#27ae60` verde      | `mediumturquoise`   |
| `--track`      | `#111` snow tracks   | `salmon`            |

Lines and tints (`--line`, `--line-faint`, `--line-strong`,
`--gold-tint`) mirror the same idea: white alphas on dark, black alphas
on light.

Code blocks use class-based Chroma (`noClasses = false`) with no syntax
stylesheet loaded: transparent background, plain text in the theme
colours. If token colours are ever wanted, generate a stylesheet with
`hugo gen chromastyles` into `assets/css/` and link it in `head.html`.

---

## Typography

Normally **MonoSpace** types, looking for them to be selfhosted.

Sizes that I am currently using for my personal website

| Role | Size (clamp)                            | Weight | Color         |
| ---- | --------------------------------------- | ------ | ------------- |
| h1   | `clamp(1.8rem, 1.5rem + 1.5vw, 2.5rem)` | 700    | whitesmoke    |
| h2   | `clamp(1.4rem, 1.2rem + 1vw, 2rem)`     | 700    | palegoldenrod |
| h3   | `clamp(1.1rem, 1rem + 0.5vw, 1.5rem)`   | 400    | salmon        |
| Body | `clamp(1rem, 0.9rem + 0.5vw, 1.3rem)`   | 300    | whitesmoke    |

In case that it is not possible, being for the search of performance or whatever
reason, our design must align with device fonts. As they are the fastest and
most available option for most of our design.

---

## Borders

- Thickness: `1.5px` everywhere
- Style: solid
- No border-radius anywhere — not even `1px`
- Navbar bottom border: `1px solid rgba(255, 255, 255, 0.12)` (subtle separator
  on black)
- Active nav item: `border-bottom: 1.5px solid salmon`

---

## Pop-Card Component

The primary interactive component. A flat card with a hard offset shadow that
appears on hover, translating the card diagonally to create a lift effect.

### Structure

```
.pop-card-outer        — wrapper; positions the shadow via ::after
  .pop-card            — the visible face of the card
```

### Behaviour

- At rest: shadow (`::after`) is `opacity: 0`; card is at its natural position
- On hover: shadow becomes `opacity: 1`; card translates `(-4px, -4px)`
- Shadow is offset `8px` right and `8px` down from the card face

### Modifiers

| Class                     | Effect                                                             |
| ------------------------- | ------------------------------------------------------------------ |
| `.pop-gold`               | Secondary colour variant (palegoldenrod accent)                    |
| `.pop-card--flush`        | Removes padding; allows image or content to bleed to the card edge |
| `.pop-card-outer--inline` | Sets `display: inline-block` on the outer wrapper                  |

---

## Shadow Patterns

The `::after` pseudo-element on `.pop-card-outer` carries the offset shadow. The
fill of that shadow can use different CSS gradient patterns, each referencing a
Colombian geometric tradition.

| Name        | CSS Technique                                | Cultural Reference                 |
| ----------- | -------------------------------------------- | ---------------------------------- |
| Dot grid    | `radial-gradient` circle repeat              | US mid-century                     |
| Diamond net | Two crossing `linear-gradient` at 45° / 135° | Vueltiao hat weave structure       |
| Zigzag      | Four triangle gradients                      | Current default; Colombian textile |
| Escalonado  | Staircase `linear-gradient` at 45°           | Muisca gold work / Andean textiles |
| Net + dots  | Diamond net + centred dot                    | Vueltiao multi-band border         |

---

## Layout

### Content

- Max width: `900px`, centred
- Top padding: `8rem` (navbar clearance)
- Bottom padding: `4rem`
- Side padding: `1rem`

### Navbar

- Position: fixed
- `z-index: 1030`
- Background: `#000`
- Border bottom: `1px solid rgba(255, 255, 255, 0.12)`
- Active item: `color: salmon; border-bottom: 1.5px solid salmon`

### Footer

- Position: fixed
- `z-index: 1030`
- Background: `#000`
