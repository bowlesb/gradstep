# Gradstep mark: concepts (2026-10-15)

Owner: "the right logo looks simple from further away but up close has more complex design nuances … Somehow an
agent needs to avoid an amateurish look. There is a new theme I'd like to explore around showing differentiation as a
central concept in a logo — possibly with half of a parabola with a line beside it. Cast a wide creative net."

## Method

No final SVG was written by hand. Every mark is computed in `gen/` (Python, numpy): a true parabola y = ax², its exact
tangent from the derivative, chords for secants, gradient-descent iterates x_{k+1} = x_k − η f′(x_k), a direction field
for y′ = 2x, a sideways parabola for the pilcrow's bowl. Strokes are outlines, not SVG strokes: a centre line, a width
along it (a designed profile along the arc length; an early broad-nib model was dropped because it kinked where the
stroke turned through the nib angle), ends cut along the curve's normal, then smoothed into cubic Béziers (centripetal
Catmull-Rom). Each round was rendered with Chromium (`gen/render.mjs`) at 256, 64, 32 and 16 px in a home-screen
squircle and judged by eye; weak directions were dropped quickly.

**Simple far, nuanced near** is built in, not added: each finalist has a large icon in three layers (`background`:
the field, a soft glow, very faint grain; `middle`: hairlines that only show up close — the parabola continuing past
the ink, the parabola's other half and axis, graph paper, chords converging on the tangent, an occlusion shadow and rim
light; `foreground`: the mark) and a separate small glyph for 16–32 px that drops every hairline and thickens what
must survive. Palette: one hue (indigo field, #2C2980 → #13103C), one accent (amber #EBA83A), and paper (#F4F1E8).

## All directions (renders/contact-sheet-all.png)

| # | Direction | Meaning | Risk | Verdict |
|---|---|---|---|---|
| A1 | Half-parabola, tangent on the flank | The derivative: how things change here | The tangent merges with the steep flank into one slash | Dropped as drawn; became **Tangent** (contact moved into the bend) |
| A2 | Tangent at the vertex | The minimum, slope zero: understanding reached | Reads as a hockey stick or an underline | Dropped |
| A3 | Secants converging to the tangent | The limit that defines the derivative | Busy at mid sizes; secants vanish small | Kept as an up-close layer in **Page** |
| A4 | A gradient step: along the tangent from x₀, landing on the curve | Grad-step, literally | Reads as a diagram; needs dots | Dropped; its idea returns in "Descent" |
| A5 | A G from a sideways parabola and its axis | Monogram | The bar reads as a minus; forced | Dropped |
| A6 | A ruler beside the curve, parallel to a tangent | Approximating locally | Ambiguous; reads as "/ /" | Dropped |
| A7 | f and f′ side by side: x² and its derivative 2x | Differentiation turns a curve into a line | Reads as "J/" or "//" | Dropped |
| A8 | Bowl and ball (osculating circle at the minimum) | Converging to the minimum | Clip-art | Dropped |
| B1 | ∇ refined (the current mark's family) | The gradient | Generic in ML tooling; already explored | Dropped |
| B2 | Contours of a quadratic bowl and one step | Optimisation landscape | A target | Dropped |
| B3 | A staircase converging to the minimum | Steps that shrink as they converge | A bar chart; crude | Dropped after one refinement (T1) |
| B4 | A page folded along a parabola | Reading + math | A generic document icon | Dropped; the idea returns as **Page** |
| B5 | A loupe turning a line of text into a curve | Close reading | The search icon | Dropped |
| B6 | A pilcrow (¶) whose bowl is a parabola | The paragraph every answer cites | A text-editor "formatting" icon | Kept → **Pilcrow** |
| B7 | A lowercase g from a bowl and a hook | Monogram | Weak, generic | Dropped |
| B8 | ∂, the sign of differentiation | Differentiation as notation | Hard to draw well; Fraunces has no ∂ to start from | Developed twice (D1, r3-partial); not a finalist yet |
| B9 | Solid forms: the region above a parabola and a supporting line | Convexity; the tangent as a supporting line | A cup with a stick | Dropped; taught that filled forms survive 16 px |
| B10 | A page curling from the spine (half-parabola and its axis) | Reading | Reads as "r" or γ | Dropped |
| B11 | A direction field of y′ = 2x with one solution | The curve emerges from its slopes | A bowl at small sizes; busy large | Dropped |
| B12 | A parabolic reflector bringing rays to the focus | Focus, understanding | A satellite dish or Wi-Fi | Dropped |
| S1–S3 | The icon split by a half-parabola, the tangent touching the boundary | A graph, and a page's edge | Diagrammatic | Developed → **Page** |
| K1–K2 | A broad-nib half-parabola and a long tangent | Calligraphy and calculus | The line crossed the ink | Developed → **Tangent** |
| R1 | x² and 2x from one origin | Curve and derivative together | Reads as "J/" | Dropped |
| r3-descent | Gradient descent drawn as its shrinking tangent steps | Grad-step | A squiggle | Dropped |
| p2–p4 | Pilcrow bowls: a full sideways parabola (D), a teardrop (lower half-parabola + quarter-ellipse), a soft cup | Which reads as ¶ | D looks like a leaf; the cup like a bucket | Teardrop kept |

## Finalists

1. **Tangent** (`finalists/tangent/`). A half-parabola in ink and its tangent: an amber line whose edge touches the
   ink's outer edge at one point in the bend, then parts from it both ways. Far: a stroke and a line that touch. Near:
   the true parabola continues as a hairline past each cut end (the ink is one segment of an infinite curve; the
   ends are cut along the normal), two draughtsman's ticks mark the contact, the ink carries a faint tonal sweep, a
   soft glow sits behind the contact, grain. The most direct form of the owner's theme.
2. **Pilcrow** (`finalists/pilcrow/`). The paragraph mark the product cites everything with. Its bowl's lower edge is
   half of a sideways parabola running from its vertex into the stem; the second stem, in amber, is the line beside
   it. Near: the parabola's other half and its axis appear as hairlines. The most legible at 16 px and the most
   product-specific; it carries the theme quietly.
3. **Page** (`finalists/page/`). The half-parabola divides the icon: the field above, a sheet of graph paper below
   whose edge lifts. The amber tangent crosses the paper and touches the edge at one marked point. Near: occlusion
   under the lifting edge, a rim of light, graph hairlines, chords above the curve converging on the tangent. The most
   atmospheric; the most "icon-like" in the iOS sense, and the most literal.

## Typeface

The lockups set "Gradstep" in **Fraunces** (SIL Open Font License 1.1, `fonts/OFL-Fraunces.txt`) at wght 540, opsz 72,
SOFT 0, WONK 0, tracking −1.2 %, shaped by HarfBuzz (`gen/wordmark.py`) and outlined, so the lockup needs no font. The
landing page draft uses the platform serif (New York on Apple devices) for headings; Fraunces is close in spirit and
licensed for a logo.

## Regenerate

```
python3 gen/concepts.py && python3 gen/round2.py && python3 gen/marks.py && python3 gen/pilcrow_variants.py
python3 gen/finalists.py && python3 gen/mocks.py
node gen/render.mjs sheet renders/all-concepts renders/contact-sheet-all.png --sizes=256,64
node gen/render.mjs png finalists/tangent/icon.svg finalists/tangent/icon-1024.png 1024
python3 gen/review.py   # review.html
```
