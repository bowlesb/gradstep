"""review.html: one self-contained page (no external requests) with the contact sheet, the three finalists at every
size and in context, and the decisions left to the owner."""
import base64, io, os
from PIL import Image
ROOT = os.path.join(os.path.dirname(__file__), '..')
P = lambda *a: os.path.join(ROOT, *a)
def svg_uri(path): return 'data:image/svg+xml;base64,' + base64.b64encode(open(path, 'rb').read()).decode()
def webp_uri(path, width=None, q=78):
    im = Image.open(path).convert('RGB')
    if width and im.width > width: im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
    b = io.BytesIO(); im.save(b, 'WEBP', quality=q, method=6)
    return 'data:image/webp;base64,' + base64.b64encode(b.getvalue()).decode()

FINALISTS = [
    ('tangent', 'Tangent', 'Recommended',
     'A half-parabola in ink and its tangent: an amber line whose edge touches the ink at one point in the bend and parts from it on both sides. It is your theme said as plainly as possible, and the product\'s promise in one picture: one exact point of contact with the source.',
     'Up close: the true parabola continues as a hairline past each end (the ink is one segment of an infinite curve, its ends cut along the normal); two draughtsman\'s ticks mark the contact; the ink carries a faint tonal sweep; a soft glow sits behind the contact; fine grain. At 16–32 px the glyph drops all of that and thickens the stroke and the line.',
     'A curve-and-line can drift toward "swoosh"; the tangent and the normal-cut ends keep it mathematical. The amber line is thin at 60 pt by design; if it feels too quiet on the home screen, thicken it from 15 to 20 units.'),
    ('pilcrow', 'Pilcrow', 'Most legible',
     'The paragraph mark that every Gradstep answer cites with. Its bowl\'s lower edge is half of a sideways parabola running from its vertex into the stem; the second stem, in amber, is the line beside it. The theme is there, quietly; the product is unmistakable.',
     'Up close: the parabola\'s other half and its axis appear as hairlines, showing the bowl is a parabola; bowl and stem are one outline with one light. At 16 px it is still a ¶.',
     'A pilcrow is also the "show formatting" button in word processors. The amber stem and the indigo field separate it, but the association never fully goes away.'),
    ('page', 'Page', 'Most atmospheric',
     'The half-parabola divides the icon: the field above, a sheet of graph paper below whose edge lifts. The amber tangent crosses the paper and touches the edge at one marked point. A graph and a page at once.',
     'Up close: occlusion under the lifting edge, a rim of light on the field side, graph-paper hairlines, chords above the curve converging on the tangent (the limit that defines it). Far: two tones and one amber line.',
     'The most literal of the three (a textbook figure), and it relies on the square: as a mark without its field (in the lockup, on paper) it weakens.'),
]

def sizes_row(n):
    icon, glyph = svg_uri(P('finalists', n, 'icon.svg')), svg_uri(P('finalists', n, 'glyph.svg'))
    cells = ''.join(f'<figure><img src="{icon if s > 32 else glyph}" width="{s}" height="{s}" style="border-radius:{s * 0.2237:.1f}px" alt=""><figcaption>{s}</figcaption></figure>' for s in [256, 180, 128, 64, 32, 16])
    return f'<div class="sizes">{cells}</div>'

cards = ''
for n, title, tag, idea, near, risk in FINALISTS:
    cards += f'''<section class="card" id="{n}"><div class="head"><h2>{title}</h2><span class="tag">{tag}</span></div>
<div class="hero"><img class="big" src="{svg_uri(P('finalists', n, 'icon.svg'))}" alt="{title}: app icon"><div class="text"><p>{idea}</p><p class="muted">{near}</p><p class="muted"><b>Risk.</b> {risk}</p>
<p class="files">finalists/{n}/: icon.svg · background.svg · middle.svg · foreground.svg · glyph.svg · lockup-light.svg · lockup-dark.svg · icon-1024.png</p></div></div>
{sizes_row(n)}
<div class="lockups"><img src="{svg_uri(P('finalists', n, 'lockup-light.svg'))}" alt="{title} lockup on light"><img src="{svg_uri(P('finalists', n, 'lockup-dark.svg'))}" alt="{title} lockup on dark"></div>
<details><summary>In context: home screen, Dock, browser tab, the landing page header</summary><img class="mock" src="{webp_uri(P('renders', 'mocks', n + '.png'), 1400)}" alt="{title} in context"></details>
</section>'''

html = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Gradstep mark review</title><style>
:root{{--bg:#F4F2EC;--ink:#1B1A22;--muted:#5D5C68;--panel:#FFFFFF;--rule:#E3DFD5;--accent:#3F42B8}}
@media(prefers-color-scheme:dark){{:root{{--bg:#111116;--ink:#ECEBF2;--muted:#A3A2B2;--panel:#18181F;--rule:#2A2A33;--accent:#B5B8FF}}}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--ink);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}
main{{max-width:1080px;margin:0 auto;padding:40px 16px 80px}}h1{{font:600 34px/1.15 ui-serif,"New York",Georgia,serif;margin:0 0 10px;letter-spacing:-.01em}}
h2{{font:600 24px ui-serif,"New York",Georgia,serif;margin:0}}.lede{{font-size:18px;color:var(--muted);max-width:760px}}
.card{{background:var(--panel);border:1px solid var(--rule);border-radius:16px;padding:24px;margin:28px 0}}
.head{{display:flex;align-items:center;gap:12px;margin-bottom:16px}}.tag{{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--accent);border:1px solid currentColor;border-radius:999px;padding:2px 10px}}
.hero{{display:grid;grid-template-columns:minmax(0,320px) minmax(0,1fr);gap:28px;align-items:start}}.big{{width:100%;max-width:320px;height:auto;border-radius:22.37%;display:block}}
.muted{{color:var(--muted)}}.files{{font:12px ui-monospace,Menlo,monospace;color:var(--muted)}}
.sizes{{display:flex;align-items:flex-end;gap:18px;flex-wrap:wrap;margin:22px 0;padding:16px;border-radius:12px;background:var(--bg)}}.sizes figure{{margin:0;text-align:center}}.sizes img{{display:block}}
figcaption{{font-size:12px;color:var(--muted);margin-top:6px}}.lockups{{display:flex;flex-direction:column;gap:10px;margin:8px 0 14px}}.lockups img{{max-width:100%;height:auto;max-height:110px;width:auto;align-self:flex-start;border-radius:10px;border:1px solid var(--rule)}}
details summary{{cursor:pointer;color:var(--accent);font-weight:600}}.mock{{max-width:100%;height:auto;margin-top:12px;border-radius:10px}}
.sheet{{max-width:100%;height:auto;border-radius:12px;border:1px solid var(--rule)}}ol li,ul li{{margin:6px 0}}
@media(max-width:700px){{.hero{{grid-template-columns:1fr}}.big{{max-width:240px}}}}
</style></head><body><main>
<h1>A new mark for Gradstep</h1>
<p class="lede">Three finalists from forty explorations, each computed rather than hand-drawn: a true parabola, its exact tangent, strokes as outlines with ends cut along the normal. Each is simple at 16 px and has a second layer of detail at app-icon size: the hairlines and shading only show up close.</p>
<p><b>Recommendation: Tangent.</b> It is your theme in its clearest form (a half-parabola and the line that touches it once), it says what the product does (one exact point of contact with the source), it stays itself at every size, and it is unlike the reading and AI icons around it. Pilcrow is the safest choice if legibility at 16 px matters most; Page is the boldest home-screen presence but the most literal.</p>
{cards}
<section class="card"><h2>Every direction explored</h2><p class="muted">Twenty first-round directions (half-parabola and tangent variations; ∇, contours, a converging staircase, a folded page, a loupe, a pilcrow, monograms, ∂, a direction field, a reflector), then three rounds of development. Each is listed with its meaning, risk and why it was kept or dropped in concepts.md.</p>
<img class="sheet" src="{webp_uri(P('renders', 'contact-sheet-all.png'), 1600, 80)}" alt="Contact sheet of all forty explorations at 256 and 64 px"></section>
<section class="card"><h2>For you to decide</h2><ol>
<li><b>The mark:</b> Tangent, Pilcrow or Page, or a direction from the sheet to push further (∂ came close and would need a type designer's hand).</li>
<li><b>The accent:</b> amber is the second colour in all three. Keep it, or let the tangent be a lighter indigo for a one-colour system.</li>
<li><b>The wordmark:</b> Fraunces (SIL OFL 1.1, open-licensed) at a book weight. Alternatives: the platform serif the landing page uses (not licensable for a logo), or a sans for a more tool-like voice.</li>
<li><b>The app icon's appearances:</b> iOS also asks for dark and tinted versions. The layered SVGs (background, middle, foreground) are ready for Icon Composer; the tinted version would be the foreground alone.</li>
<li><b>A final pass by hand:</b> the geometry is exact; a designer's eye on optical balance (stroke weight at the contact point, the ¶ bowl's top curve) would be the last 5 %.</li>
</ol></section>
</main></body></html>'''
open(P('review.html'), 'w').write(html)
print(round(len(html) / 1024), 'KB')
