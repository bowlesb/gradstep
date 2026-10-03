# iOS PWA Full-Screen Viewport: The 62px Problem

## The Issue

When running as a standalone PWA on iOS (added to Home Screen), the app wasn't using the full screen height. The bottom tab bar icons sat at the same vertical position as in regular Chrome/Safari, wasting the extra screen space that standalone mode provides.

## Root Cause

iOS Safari's standalone PWA mode does **not** extend `window.innerHeight` to cover the full physical screen, even with `viewport-fit=cover` set in the viewport meta tag.

On an iPhone with a notch (e.g. iPhone X/11/12/13/14), the numbers look like this:

```
screen.height:        874px   ← full physical screen (in CSS pixels)
window.innerHeight:   812px   ← what the browser reports as the viewport
--sat (safe area top): 62px   ← status bar + notch
--sab (safe area bot): 34px   ← home indicator
```

The viewport is `874 - 62 = 812px`. It starts **below** the status bar and extends to the bottom of the screen. The `env(safe-area-inset-bottom)` correctly reports 34px for the home indicator area within that viewport.

The problem: the body was `position: fixed` with `top: 0; bottom: 0`, which constrains it to the viewport (812px). Since the viewport doesn't include the status bar area, and `padding-top: var(--sat)` (62px) was eating into that 812px to push content below the notch, the effective layout area was only 750px — the same as a regular browser with its chrome.

## What Didn't Work

1. **`height: 100dvh`** — Resolves to `window.innerHeight` (812px), same problem.
2. **`height: -webkit-fill-available`** — Same, doesn't extend past the viewport.
3. **`@media (display-mode: standalone)` + `bottom: -34px`** — Either the media query didn't match on iOS, or negative `bottom` on a fixed element doesn't extend past the viewport boundary.
4. **`height: 100vh`** — Same as `innerHeight` on iOS.

All CSS-only approaches fail because iOS caps the viewport at 812px regardless. The viewport simply does not report the full screen height.

## The Fix

JavaScript at page load detects standalone mode and sets a CSS custom property to `screen.height`, which **does** report the true full-screen dimension (874px):

### `layout.tsx` — inline script (runs before React hydration)
```js
if (navigator.standalone || window.matchMedia("(display-mode: standalone)").matches) {
  document.documentElement.style.setProperty("--app-height", screen.height + "px");
}
```

### `globals.css` — html and body
```css
html {
  --app-height: 100%;        /* default for non-standalone */
  height: var(--app-height);
}

body {
  height: var(--app-height, 100%);
  position: fixed;
  top: 0;
  left: 0;
  width: 100%;
  /* NOTE: no bottom: 0 — that would cap height to viewport */
}
```

### How it works

| Mode | `--app-height` | Body height | Result |
|------|---------------|-------------|--------|
| Regular browser | `100%` (default) | viewport height | Normal behavior |
| Standalone PWA | `874px` (screen.height) | full screen | Tab bar reaches true bottom |

The `.mobile-app-container` then uses `height: 100%` (of the 874px body), with `padding-top: var(--sat)` to avoid the notch. The tab bar at the bottom uses `padding-bottom: var(--sab)` to keep icons above the home indicator. The net effect is ~28px more usable space compared to a regular browser.

## Key Takeaway

On iOS standalone PWAs, **you cannot rely on CSS viewport units to get the full screen height**. The only reliable source of the true screen dimension is `screen.height` via JavaScript. Set it as a CSS custom property early (before paint) and use it for your root layout height.
