"""Context mocks for each finalist: iOS home screen (60 pt), macOS Dock, a browser tab, the landing page header; and a
size strip (1024 → 16). Writes renders/mocks/<name>.html (rendered to PNG by render.mjs page)."""
import base64, os
ROOT = os.path.join(os.path.dirname(__file__), '..')
OUT = os.path.join(ROOT, 'renders', 'mocks'); os.makedirs(OUT, exist_ok=True)
NAMES = ['tangent', 'pilcrow', 'page']
uri = lambda p: 'data:image/svg+xml;base64,' + base64.b64encode(open(p, 'rb').read()).decode()

# neutral neighbours: plain tinted squares with a simple shape, so the mark is judged among icons, not brands
NEIGH = ['#E4572E', '#3BB273', '#2D7DD2', '#F2C14E', '#8E44AD', '#16A085', '#E67E22', '#95A5A6', '#1ABC9C', '#C0392B', '#34495E', '#F39C12', '#7F8C8D', '#2980B9', '#D35400']
def neighbour(i, size):
    c = NEIGH[i % len(NEIGH)]
    shape = ['<circle cx="50" cy="50" r="22" fill="white" opacity=".9"/>', '<rect x="28" y="28" width="44" height="44" rx="8" fill="white" opacity=".9"/>',
             '<path d="M50 24L76 72H24Z" fill="white" opacity=".9"/>'][i % 3]
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="{c}"/>{shape}</svg>'
    return 'data:image/svg+xml;base64,' + base64.b64encode(svg.encode()).decode()

CSS = """body{margin:0;font:13px -apple-system,BlinkMacSystemFont,sans-serif;background:#ECEAE4;color:#1d1d22}
.wrap{display:grid;grid-template-columns:auto auto;gap:28px;padding:28px;align-items:start}
.phone{width:390px;height:520px;border-radius:44px;padding:56px 26px 0;box-sizing:border-box;display:grid;grid-template-columns:repeat(4,60px);gap:26px 28px;align-content:start}
.phone.light{background:linear-gradient(160deg,#cfd8ea,#f3e7d8)} .phone.dark{background:linear-gradient(160deg,#1c2235,#3b2a3f)}
.app{display:flex;flex-direction:column;align-items:center;gap:5px;font-size:11px}.light .app{color:#1d1d22}.dark .app{color:#fff}
.app img{width:60px;height:60px;border-radius:13.4px;display:block;box-shadow:0 1px 2px rgba(0,0,0,.15)}
.dock{grid-column:1/-1;display:flex;gap:10px;padding:10px 14px;border-radius:22px;background:rgba(255,255,255,.55);backdrop-filter:blur(8px);width:max-content;box-shadow:0 8px 30px rgba(0,0,0,.18);border:1px solid rgba(255,255,255,.6)}
.dock img{width:64px;height:64px;display:block}.dockwrap{grid-column:1/-1;padding:30px;border-radius:18px;background:linear-gradient(135deg,#7a8fb8,#c7a98a);display:flex;justify-content:center}
.mac{width:64px;height:64px;position:relative}.mac img{position:absolute;inset:6px;width:52px;height:52px;border-radius:11.6px;box-shadow:0 2px 4px rgba(0,0,0,.25)}
.tabs{grid-column:1/-1;background:#DEE1E6;border-radius:12px 12px 0 0;padding:8px 8px 0;display:flex;gap:2px;width:820px}
.tab{display:flex;align-items:center;gap:8px;padding:9px 14px;border-radius:9px 9px 0 0;font-size:12.5px;color:#3c4043;width:220px}
.tab.on{background:#fff}.tab img{width:16px;height:16px;border-radius:3px}.addr{grid-column:1/-1;width:820px;margin-top:-28px;background:#fff;padding:8px 12px;box-sizing:border-box;border-bottom:1px solid #ddd}
.addr span{display:block;background:#F1F3F4;border-radius:16px;padding:6px 14px;color:#5f6368;font-size:12.5px}
.site{grid-column:1/-1;width:820px;background:#faf9f6;border-radius:0 0 12px 12px;margin-top:-28px;padding:18px 28px 40px;box-sizing:border-box}
.site header{display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #e6e3dc;padding-bottom:16px}
.site header img{height:34px;display:block}.site nav{display:flex;gap:22px;color:#5b5b67;font-size:13px}.site nav b{color:#3f42b8}
.site h1{font:500 40px ui-serif,"New York",Georgia,serif;letter-spacing:-.015em;margin:36px 0 0;color:#17171c}
.sizes{grid-column:1/-1;display:flex;align-items:flex-end;gap:18px;padding:18px;background:#fff;border-radius:12px}
.sizes figure{margin:0;text-align:center;font-size:11px;color:#666}.sizes img{display:block;margin:0 auto 6px}
.darkstrip{background:#15151a}.darkstrip figure{color:#999}
h2{grid-column:1/-1;margin:6px 0 -14px;font-size:14px}"""

for n in NAMES:
    icon = uri(os.path.join(ROOT, 'finalists', n, 'icon.svg')); glyph = uri(os.path.join(ROOT, 'finalists', n, 'glyph.svg'))
    lockup = uri(os.path.join(ROOT, 'finalists', n, 'lockup-light.svg'))
    labels = ['Mail', 'Notes', 'Files', 'Books', 'Maps', 'Photos', 'Clock', 'Podcasts', 'Gradstep', 'Calendar', 'News', 'Weather']
    def grid(cls):
        cells = ''
        for i, lab in enumerate(labels):
            src = icon if lab == 'Gradstep' else neighbour(i, 60)
            cells += f'<div class="app"><img src="{src}"><span>{lab}</span></div>'
        return f'<div class="phone {cls}">{cells}</div>'
    dock = ''.join(f'<div class="mac"><img src="{icon if i == 4 else neighbour(i + 3, 64)}"></div>' for i in range(8))
    sizes = ''.join(f'<figure><img src="{icon if s >= 64 else glyph}" width="{s}" height="{s}" style="border-radius:{s * 0.2237}px">{s}</figure>' for s in [256, 180, 128, 64, 32, 16])
    gsizes = ''.join(f'<figure><img src="{glyph}" width="{s}" height="{s}" style="border-radius:{s * 0.2237}px">{s}</figure>' for s in [64, 32, 24, 16])
    html = f"""<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style></head><body><div class="wrap">
<h2>iOS home screen, 60 pt (light and dark wallpaper)</h2>{grid('light')}{grid('dark')}
<h2>macOS Dock</h2><div class="dockwrap"><div class="dock">{dock}</div></div>
<h2>Browser tab and the landing page header</h2>
<div class="tabs"><div class="tab"><img src="{neighbour(2, 16)}">Inbox</div><div class="tab on"><img src="{glyph}">Gradstep · Understand the paper</div><div class="tab"><img src="{neighbour(5, 16)}">arXiv</div></div>
<div class="addr"><span>gradstep.ai</span></div>
<div class="site"><header><img src="{lockup}"><nav><span>How it works</span><b>Join the beta</b></nav></header><h1>Understand the paper,<br>not a summary of it.</h1></div>
<h2>Sizes: the icon to 64, the small glyph below</h2><div class="sizes">{sizes}</div><div class="sizes darkstrip">{gsizes}</div>
</div></body></html>"""
    open(os.path.join(OUT, f'{n}.html'), 'w').write(html)
print('mocks written')
