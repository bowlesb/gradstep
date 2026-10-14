// The knowledge map a Study builds (lib/study.ts): what the reader has shown they know, what is in progress, how the
// ideas connect, and the path taken. Memory only, with the open chat.
import { useMemo, useState } from 'react';
import { LINK_TEXT, NEXT_TEXT, STATE_TEXT, stateCounts, studyMermaid, type StudyMap } from '../lib/study';
import { DiagramFrame } from './Diagram';
import { Icon } from './icons';

export function StudyPanel({ map, busy, onPassage, onEnd }: { map: StudyMap; busy: boolean; onPassage: (paragraph: number) => void; onEnd: () => void }) {
  const [open, setOpen] = useState(true), [view, setView] = useState<'map' | 'journey' | 'concepts'>('map');
  const counts = stateCounts(map), focus = map.concepts.find(c => c.id === map.focus) ?? null;
  const source = useMemo(() => studyMermaid(map), [map]);
  const byID = new Map(map.concepts.map(c => [c.id, c]));
  const summary = map.concepts.length
    ? `${map.concepts.length} ${map.concepts.length === 1 ? 'concept' : 'concepts'} · ${counts.known + counts.verified} known · ${counts.learning} learning · ${counts.unknown} not yet`
    : 'Built from your answers as you go';
  return <section className="study-panel" data-testid="study-panel" aria-label="Knowledge map">
    <div className="study-bar">
      <button type="button" className="study-toggle" aria-expanded={open} onClick={() => setOpen(o => !o)}><Icon name={open ? 'chevronDown' : 'chevronUp'} size={12} /><strong>Knowledge map</strong></button>
      <span className="fine study-summary" data-testid="study-summary" title={summary}>{summary}</span>
      <button type="button" className="link small" disabled={busy} onClick={onEnd} data-testid="study-end">End study</button>
    </div>
    {open && <div className="study-body">
      <p className="fine study-now" data-testid="study-now">{focus ? <><strong>Now:</strong> {focus.label} · {NEXT_TEXT[map.next]}</> : NEXT_TEXT[map.next]}</p>
      {map.concepts.length > 0 && <>
        <div className="study-views" role="group" aria-label="Knowledge map view">
          {(['map', 'journey', 'concepts'] as const).map(v => <button key={v} type="button" className={`seg${view === v ? ' on' : ''}`} aria-pressed={view === v} onClick={() => setView(v)}>{{ map: 'Map', journey: 'Journey', concepts: 'Concepts' }[v]}</button>)}
        </div>
        {view === 'map' && <div className="study-graph" data-testid="study-graph"><DiagramFrame key={source} source={source} /></div>}
        {view === 'journey' && <ol className="study-journey" data-testid="study-journey" aria-label="Concepts in the order explored">
          {map.journey.map((id, i) => { const c = byID.get(id); return c ? <li key={`${id}-${i}`} className="study-step">{i > 0 && <span className="study-arrow" aria-hidden="true">→</span>}<span className={`study-chip ${c.state}`} title={STATE_TEXT[c.state]}>{c.label}</span></li> : null; })}
        </ol>}
        {view === 'concepts' && <ul className="study-concepts" data-testid="study-concepts">
          {map.concepts.map(c => <li key={c.id} className="study-concept">
            <span className={`study-chip ${c.state}`}>{STATE_TEXT[c.state]}</span><strong>{c.label}</strong>
            {c.paragraphs.map(n => <button key={n} type="button" className="cite study-cite" onClick={() => onPassage(n)} aria-label={`Go to paragraph ${n}`}>¶{n}</button>)}
            {c.note && <span className="fine study-note">{c.note}</span>}
            {map.links.filter(l => l.from === c.id).map(l => <span key={`${l.from}-${l.to}`} className="fine study-link">{LINK_TEXT[l.kind]} {byID.get(l.to)?.label}</span>)}
          </li>)}
        </ul>}
        <ul className="study-legend" aria-label="Map legend">
          {(['unknown', 'learning', 'known', 'verified'] as const).map(s => <li key={s}><span className={`study-dot ${s}`} aria-hidden="true" />{STATE_TEXT[s]} · {counts[s]}</li>)}
          {view === 'map' && <li className="study-edges">solid: builds on · dotted: goes deeper · line: related · thick border: now</li>}
        </ul>
      </>}
    </div>}
  </section>;
}
