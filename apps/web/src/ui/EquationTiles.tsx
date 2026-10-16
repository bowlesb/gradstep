// Contents › Equations › View as tiles (owner, build 62: "How possible is it to use a tile view similar to figures?"):
// the paper's display equations typeset by the reader's own MathML and styles in one sandboxed document (not a frame per
// tile), each tile named as its row is. A tile goes where its row goes: the equation in the paper, with Back.
import { useEffect, useMemo, useRef } from 'react';
import type { VerifiedBundle } from '../lib/bundle';
import { equationNumbers } from '../lib/equation';
import { contentsEquations } from '../lib/paper-contents';
import { equationTilesDocument } from '../reader/equation-frame';
import { Dialog, SheetTop } from './common';

export function EquationTiles({ bundle, theme, onClose, onEquation }: {
  bundle: VerifiedBundle; theme: 'light' | 'dark'; onClose: () => void; onEquation: (id: string) => void;
}) {
  const tiles = useMemo(() => { const numbers = equationNumbers(bundle); return contentsEquations(bundle.index, id => numbers.get(id) ?? null); }, [bundle]);
  const doc = useMemo(() => equationTilesDocument(bundle, tiles, { parentOrigin: location.origin, theme, size: 18 }), [bundle, tiles, theme]);
  const frame = useRef<HTMLIFrameElement>(null);
  const latest = useRef(onEquation); latest.current = onEquation;
  useEffect(() => {
    const ids = new Set(tiles.map(t => t.id));
    const receive = (event: MessageEvent) => {
      if (!frame.current || event.source !== frame.current.contentWindow || event.data?.gradstep !== 'equation-tile') return;
      const id = event.data.id;
      if (typeof id === 'string' && ids.has(id)) latest.current(id);
    };
    addEventListener('message', receive);
    return () => removeEventListener('message', receive);
  }, [tiles]);
  return <Dialog open onClose={onClose} title="Equations" wide className="equation-tiles-dialog">
    <div className="equation-tiles">
      <SheetTop onClose={onClose} testID="equation-tiles-close"><h2>Equations · {tiles.length}</h2></SheetTop>
      <iframe ref={frame} className="equation-tiles-frame" sandbox="allow-scripts" srcDoc={doc} title="Equations as tiles" data-testid="equation-tiles-frame" />
    </div>
  </Dialog>;
}
