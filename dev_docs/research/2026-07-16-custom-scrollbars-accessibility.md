# Custom Scrollbars: Accessibility & Compliance Research

**Date:** 2026-07-16
**Context:** Boss wants custom/branded scrollbars on the public publishing side. This is
an accessibility trap, so we researched compliance (WCAG 2.2 AA + EU EAA) before building.
Method: deep-research pass — 15 sources fetched, 25 claims adversarially verified
(22 confirmed, 3 refuted).

## Bottom line

**Style the *native* scrollbar with CSS (`scrollbar-color` + `scrollbar-width`) — do NOT
replace it with JavaScript.** Native styling keeps the browser's real scroll behavior, so
keyboard, touch, momentum, and screen-reader semantics all keep working for free. That's
exactly where JS scrollbars cause compliance problems. You then only have to satisfy
**3:1 contrast** and a **target-size/spacing** minimum.

Any "fancy" idea (progress bar, clickable date/heading anchors) should be **additive
navigation UI layered around the scroll area — never a replacement for native scrolling.**

## Approach comparison

| | Native CSS (`scrollbar-color`/`-width`) | `::-webkit-scrollbar` | JS overlay (SimpleBar / OverlayScrollbars) | JS "fake scroll" (perfect-scrollbar-style) |
|---|---|---|---|---|
| Visual control | Color + thin/hide | Full (radius, gradients) | Full | Full |
| A11y risk | **Lowest** — native intact | Low | Low *if* it keeps native scroll | **High** — reimplements scroll |
| Keyboard/touch/AT | Preserved automatically | Preserved | Preserved (native overflow kept) | Frequently broken |
| Effort | Trivial (2 props) | Low | Medium (dep + wiring) | Medium–High |
| Browser support | Baseline **Dec 2025** (Safari ≥26.2) ~83% | Chromium/WebKit only, non-standard | Broad | Broad |

## Verified facts (CSS-native)

- `scrollbar-width: none` hides the bar but does **not** disable scrolling — spec: "the
  element's scrollability by other means is not affected." Keyboard/touch/programmatic scroll survive.
- `scrollbar-color: <thumb> <track>` — first color = thumb, second = track.
- Standard props reached cross-browser **Baseline only in December 2025** (Safari holdout
  until 26.2; Chrome/Edge 121+, Firefox 64+). ~83% global → **`::-webkit-scrollbar` fallback
  still needed** for older Safari, and it's the only route to rounded/gradient thumbs. When
  both are present, the standard props win.
- MDN flags `::-webkit-scrollbar` non-standard and even advises against styling scrollbars
  at all ("breaks external consistency… negatively impacts usability"). Treat heavy restyling
  as a deliberate branding tradeoff.
- **Known flakiness:** MDN compat issue #29315 — `scrollbar-color` doesn't render on macOS
  Safari 26.3 with overlay scrollbars. Test on real Safari.

## WCAG criteria that apply

| Criterion | Level | Applies once you… | Pass |
|---|---|---|---|
| **1.4.11 Non-text Contrast** | AA | recolor | Thumb ≥ **3:1** vs track (and page). Ideally 4.5:1 thumb/track. Include hover/focus states. |
| **2.5.8 Target Size (Min)** | AA (2.2) | resize | Native bars are *exempt* (UA control). Once you set `scrollbar-width: thin` / narrow thumb, provide **24×24 CSS px** or passing **spacing** between bar and content. |
| **2.1.1 Keyboard** | A | (always) | Scroll container reachable by keyboard so arrows/space/PageUp-Down work. Native scroll satisfies this on modern browsers; JS replacement is the #1 way to break it. |
| 1.4.10 Reflow / 1.4.13 Hover / 2.3.3 Reduced Motion | AA | add overlays/motion | Don't trap content; respect `prefers-reduced-motion` for any smooth-scroll/animation. |

### Myths the verification killed (do NOT code to these)
- ❌ "Spec requires a visual 'you can scroll' hint when hiding the bar." **Refuted** — good UX, not required.
- ❌ "A scroll region must have `tabindex="0"`." **Oversimplified** — a focusable descendant
  also satisfies keyboard access; Firefox (and Chrome 127+) increasingly make overflow
  containers keyboard-focusable automatically. Safari/WebKit historically did **not**, so a
  keyboard-only, non-interactive scroll region may still need `tabindex="0"` + role + accessible name.

## JS libraries, ranked by a11y (only if a fully custom look is mandated)

- **SimpleBar** — safe archetype. README: "does NOT implement a custom scroll behaviour…
  keeps the native `overflow: auto`… You keep the performances/behaviours of the native scroll."
- **OverlayScrollbars** — claims native scroll fully preserved; most actively maintained.
  (2026 a11y profile not primary-verified beyond the mechanism.)
- **perfect-scrollbar / transform-driven** — higher risk; mimics scroll, can lose keyboard control. Avoid.

## Compliance — EU EAA

- **European Accessibility Act** (Directive 2019/882) **applicable 28 June 2025**, all 27
  member states, **extraterritorial** (any business placing covered products/services on the
  EU market; microenterprises *providing services* exempt). New services comply now; existing
  grandfathered to **28 June 2030**. A `.ee` site serving EU users is in scope.
- Web conformance runs through harmonized standard **EN 301 549**, which currently incorporates
  **WCAG 2.1 Level AA** (WCAG 2.2 not yet harmonized — v4.1.1 draft, ~2026). So **WCAG 2.1 AA
  is the operative benchmark today; build to 2.2 AA to be forward-safe** (2.2 adds 2.5.8 target size).
- US: ADA (WCAG in practice) + Section 508 (WCAG 2.0/2.1 AA) point at the same criteria —
  meeting WCAG 2.1/2.2 AA covers all three.

## Recommendation for our stack (Phoenix LiveView + Tailwind v4 + daisyUI 5, .ee/EU)

1. **Default to native CSS** — `scrollbar-color` (+ optional `scrollbar-width: thin`), colors
   driven by daisyUI theme tokens, scoped to app containers.
2. **`::-webkit-scrollbar` fallback** only where rounded thumbs / older Safari coverage is needed.
3. **Meet 3:1 (aim 4.5:1)** thumb-vs-track in both light and dark themes; **size/space to ≥24px
   (design 44px for touch)**.
4. **Never replace native scroll.** If a fully custom bar is mandated, use **SimpleBar** and
   wrap for LiveView (`phx-hook` + likely `phx-update="ignore"`). NOTE: the public publishing
   pages are **controller-rendered dead views**, not LiveView, so plain JS/CSS is enough there.

## Open questions to resolve during implementation

1. daisyUI 5 / Tailwind v4: built-in scrollbar utility / theme-token binding, or arbitrary
   properties / `tailwind-scrollbar` plugin?
2. LiveView admin surfaces: do DOM patches disrupt a JS scrollbar lib (need `phx-update="ignore"`)?
   (Public pages are dead views — not affected.)
3. Will EN 301 549 v4.1.1 (WCAG 2.2, 24px targets) be harmonized within our compliance window?

## Sources

Primary: [CSS Scrollbars spec](https://drafts.csswg.org/css-scrollbars/) ·
[MDN scrollbar-color](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/scrollbar-color) ·
[MDN ::-webkit-scrollbar](https://developer.mozilla.org/en-US/docs/Web/CSS/::-webkit-scrollbar) ·
[Chrome scrollbar-styling](https://developer.chrome.com/docs/css-ui/scrollbar-styling) ·
[WCAG 1.4.11](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html) ·
[WCAG 2.5.8](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html) ·
[W3C ACT keyboard-scroll rule](https://www.w3.org/WAI/standards-guidelines/act/rules/0ssw9k/proposed/) ·
[SimpleBar](https://github.com/grsmto/simplebar).
Expert/secondary: [Adrian Roselli — scrollbar usability](https://adrianroselli.com/2019/01/baseline-rules-for-scrollbar-usability.html) ·
[Adrian Roselli — keyboard scrolling](https://adrianroselli.com/2022/06/keyboard-only-scrolling-areas.html) ·
[EAA overview](https://www.accessibility.works/european-accessibility-act/).
