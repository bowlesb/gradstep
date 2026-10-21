// The local framing record (figure-framing-record.ts; FIGURE_VIEW.md "Future opt-in training signal; not collected"):
// geometry only, arXiv figures only, in memory, bounded, forgotten on sign-out. The apps' FigureFramingTests check the same.
import { afterEach, describe, expect, it } from 'vitest';
import { arxivFigure, clearFramingRecords, framingChanged, framingRecords, framingShown } from '../src/lib/figure-framing-record';

afterEach(() => clearFramingRecords());
const init = (figure = { sourceID: '2305.18290', revision: 3, figure: 'Figure 2' }) => ({ figure, surface: 'walkthrough' as const, part: 1, parts: 2,
  level: 'medium' as const, box: [0.45, 0.1, 0.99, 0.9] as [number, number, number, number], region: [0.45, 0.031936, 0.994118, 0.99002] as [number, number, number, number],
  frame: [0.352059, -0.01996, 1.007353, 1.01996] as [number, number, number, number] });

describe('the framing record', () => {
  it('names only arXiv papers\' figures', () => {
    expect(arxivFigure({ kind: 'import', source: 'arxiv', source_id: '2305.18290', source_revision: 3 }, 'Figure 2')).toEqual({ sourceID: '2305.18290', revision: 3, figure: 'Figure 2' });
    expect(arxivFigure({ kind: 'item', source: 'pdf', source_id: null, source_revision: null }, 'Figure 2')).toBeNull();
    expect(arxivFigure(null, 'Figure 2')).toBeNull();
    framingShown('x', null);
    expect(framingRecords()).toEqual([]);
  });

  it('keeps one geometry-only record per card with the final view and what the reader did', () => {
    framingShown('a', init()); framingShown('a', init());
    framingChanged('a', { view: [0.123456, 0, 1, 1], zoomed: true });
    framingChanged('a', { expanded: true });
    framingChanged('missing', { expanded: true });
    const [record, ...rest] = framingRecords();
    expect(rest).toEqual([]);
    expect(record).toEqual({ ...init(), frame: [0.3521, -0.02, 1.0074, 1.02], region: [0.45, 0.0319, 0.9941, 0.99], finalView: [0.1235, 0, 1, 1],
      zoomed: true, panned: false, expanded: true });
    expect(Object.keys(record).sort()).toEqual(['box', 'expanded', 'figure', 'finalView', 'frame', 'level', 'panned', 'part', 'parts', 'region', 'surface', 'zoomed']);
  });

  it('is bounded and forgotten on sign-out', () => {
    for (let i = 0; i < 205; i++) framingShown(`k${i}`, init());
    expect(framingRecords()).toHaveLength(200);
    clearFramingRecords();
    expect(framingRecords()).toEqual([]);
  });
});
