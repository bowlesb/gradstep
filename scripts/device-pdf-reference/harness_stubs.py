import os
import json, sys, types, re
from pathlib import Path
import numpy as np
SRC = Path(os.environ['DEVICE_REF_SRC'])  # a copy of the desktop's src/ (gradstep package)
sys.path.insert(0, str(SRC))
sys.path.insert(0, str(Path(sys.argv[0]).resolve().parent))
import rules

def stub(name, **attrs):
    m = types.ModuleType(name); m.__dict__.update(attrs); sys.modules[name] = m; return m
class _NoGrad:
    def __call__(self, f=None): return f if f else self
    def __enter__(self): return self
    def __exit__(self, *a): return False
torch = stub('torch', no_grad=_NoGrad(), tensor=np.asarray, device=lambda *a, **k: 'cpu', Tensor=object)
torch.cuda = types.SimpleNamespace(is_available=lambda: False)
stub('torch.nn', Module=object, Embedding=object, Linear=object, GRU=object); torch.nn = sys.modules['torch.nn']
stub('lxml', etree=None, html=None); stub('lxml.etree'); stub('lxml.html')
for pkg in ['gradstep', 'gradstep.bundle', 'gradstep.data', 'gradstep.eval', 'gradstep.models']:
    m = types.ModuleType(pkg); m.__path__ = [str(SRC / pkg.replace('.', '/'))]; sys.modules[pkg] = m
stub('gradstep.data.acquire', SITE='', Fetcher=object); stub('gradstep.data.papers', family_of=lambda *a: '')
stub('gradstep.eval.layout', CLASSES=['title', 'abstract', 'heading', 'paragraph', 'caption', 'footnote', 'bibitem', 'listing', 'display', 'table', 'figure'])
recorded = [dict(p, detections=p['detections']) for p in signals['pages']] if 'signals' in globals() else json.load(open(sys.argv[2]))['pages']
calls = {'page': 0}
def page_detections(det, img, thresholds, device):
    p = recorded[calls['page']]; calls['page'] += 1
    assert img.width == p['image_width'] and img.height == p['image_height'], (img.size, p['image_width'], p['image_height'])
    return [dict(d) for d in p['detections']], p['scale']
stub('gradstep.models.coreml_layout', load_detector=None, page_detections=page_detections)
class Recogniser:
    def predict_many(self, images, keep_probs=None):
        out = []
        for im in images:
            h, w = im.shape[0] - 16, im.shape[1] - 16
            latex, probs = rules.recognise(w, h)
            if keep_probs is not None: keep_probs.append(probs)
            out.append((latex, min(probs)))
        return out
stub('gradstep.models.texteller', Recogniser=Recogniser)
def render_many(items):
    return {i: '<math><mi>x</mi></math>' for i, tex, disp in items if '\\foo' not in tex}
stub('gradstep.bundle.mathml', render_many=render_many)
from gradstep.bundle import device_pdf as dp
from gradstep.models.inline_tagger import font_family, spans_of, lines_of
from gradstep.data.pdftext import read_pages
vocab = signals['tagger'] if 'signals' in globals() else json.load(open(os.environ['TAGGER_VOCAB']))
math = rules.math_ids(vocab['font_vocab'])
class Tagger:
    def spans(self, line, threshold=None):
        if len(line) < 2: return []
        return spans_of([vocab['font_vocab'].get(font_family(g.font), 0) in math for g in line[:400]])
loaded = dp.Loaded(dp.Models(), None, {}, Recogniser(), Tagger(), 'cpu')
loaded.provenance = lambda: []
