import os
"""The reference on synthetic signals (no PDF): read_pages and pdfium answer from the signals file."""
import json, sys, types
from pathlib import Path
import numpy as np
from PIL import Image
HERE = Path(sys.argv[0]).resolve().parent
sys.argv = [sys.argv[0]] + sys.argv[1:]
signals = json.load(open(sys.argv[1]))
exec(open(HERE / 'harness_stubs.py').read())
from gradstep.data import pdftext
pages = []
for i, p in enumerate(signals['pages']):
    g = p['glyphs']
    glyphs = [pdftext.Glyph(g['text'][k], g['x0'][k], g['top'][k], g['x1'][k], g['bottom'][k], g['size'][k], g['font'][k], 'text', bool(g['upright'][k])) for k in range(len(g['text']))]
    pages.append(pdftext.Page(i, p['width'], p['height'], glyphs, [], []))
class _P:
    def __init__(self, p): self.p = p
    def render(self, scale, draw_annots=False):
        w, h = (self.p['image_width'], self.p['image_height']) if abs(scale - 150 / 72) < 1e-9 else (round(self.p['width'] * scale), round(self.p['height'] * scale))
        img = Image.new('RGB', (w, h), (255, 255, 255))
        return types.SimpleNamespace(to_pil=lambda: img)
class _Doc:
    def __init__(self, *_): pass
    def __len__(self): return len(signals['pages'])
    def __getitem__(self, i): return _P(signals['pages'][i])
    def close(self): pass
dp.pdfium = types.SimpleNamespace(PdfDocument=_Doc)
dp.read_pages = lambda pdf: pages
summary = dp.Converter(loaded).convert(Path(sys.argv[2]), Path(sys.argv[3]))
print(json.dumps({k: v for k, v in summary.items() if k != 'timing'}))
