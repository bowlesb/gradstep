"""Check that newly detected inline math preserves surrounding text and original PDF places.

Reconstruct each equation from the actual native source glyphs at its claimed rectangle,
then require the reading's normalized character stream to equal the baseline. This checks
loss/duplication and placement, not recognition accuracy; inspect rendered formulas too.
"""
import argparse, collections, json, unicodedata
from html.parser import HTMLParser
from pathlib import Path

def normalized(text):
    return ''.join(unicodedata.normalize('NFKC', text).split())

def check(before, after):
    def read(root, name): return json.loads((root/name).read_text())
    old, new = read(before, 'reader.json'), read(after, 'reader.json')
    assert not old['equations'], 'this check requires the two raw-text journal baselines, not an already math-marked reading'
    op, np = read(before, 'provenance.json'), read(after, 'provenance.json')
    trace, record = read(after, 'index.json'), read(after, 'record.json')
    assert [(b['id'], b['kind']) for b in old['blocks']] == [(b['id'], b['kind']) for b in new['blocks']]
    assert op['blocks'] == np['blocks'], 'block source places changed'
    # Caption strings now contain math markup; their source text is checked with all other blocks below.
    def figures(rows): return [{k:v for k,v in r.items() if k!='caption'} for r in rows]
    assert figures(old['figures']) == figures(new['figures']) and op['figures'] == np['figures'], 'figure images or places changed'
    replacements = {}
    for eq in trace['equations']:
        page = record['pages'][eq['source']['page']]
        x0, y0, x1, y1 = eq['source']['box']; g = page['glyphs']
        assert -1 <= x0 < x1 <= page['width']+1 and -1 <= y0 < y1 <= page['height']+1
        ids = [i for i in range(len(g['text']))
               if x0-.1 <= (g['x0'][i]+g['x1'][i])/2 <= x1+.1
               and y0-.1 <= (g['top'][i]+g['bottom'][i])/2 <= y1+.1]
        ids.sort(key=lambda i: g['x0'][i])
        replacements[eq['id']] = ''.join(g['text'][i] for i in ids)
        assert replacements[eq['id']], 'formula has no original glyphs'

    class Parser(HTMLParser):
        def __init__(self):
            super().__init__(); self.depth=0; self.block=None; self.eq=None; self.text=collections.defaultdict(str)
        def handle_starttag(self, tag, attrs):
            attrs=dict(attrs)
            if tag in ['img', 'meta', 'link', 'br', 'hr', 'input']: return
            self.depth += 1
            if 'data-reader-block' in attrs: self.block=(attrs['data-reader-block'], self.depth)
            if 'data-reader-equation' in attrs:
                self.eq=self.depth
                if self.block: self.text[self.block[0]] += replacements[attrs['data-reader-equation']]
        def handle_endtag(self, tag):
            if self.eq == self.depth: self.eq=None
            if self.block and self.block[1] == self.depth: self.block=None
            self.depth -= 1
        def handle_data(self, data):
            if self.block and self.eq is None: self.text[self.block[0]] += data

    parser=Parser(); parser.feed((after/'index.html').read_text()); checked=0
    for block in old['blocks']:
        assert normalized(block['text']) == normalized(parser.text[block['id']]), 'text changed: '+block['id']
        checked += 1
    return {'blocks': len(old['blocks']), 'text_blocks_checked': checked, 'new_equations': len(new['equations']),
            'source_places_equal': True, 'figures_equal': True, 'surrounding_text_conserved': True}

if __name__ == '__main__':
    p=argparse.ArgumentParser(); p.add_argument('before',type=Path); p.add_argument('after',type=Path); p.add_argument('out',type=Path)
    a=p.parse_args(); result=check(a.before,a.after); a.out.write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(result))
