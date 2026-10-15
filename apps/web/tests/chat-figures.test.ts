import { describe, expect, it } from 'vitest';
import { decodeStoredFigureParts, figureFor, figureMentions, parseFigureParts, storedFigurePartsText } from '../src/lib/chat-figures';
import { requestBody, makeRequest } from '../src/lib/chat';

describe('figures in chat (CHAT.md "Figures in chat")', () => {
  it('finds the figures and tables a question names, in order, once each', () => {
    expect(figureMentions('Compare Fig. 3 with Table 1, then figure 3 again and Figs 2')).toEqual([
      { kind: 'figure', number: 3 }, { kind: 'table', number: 1 }, { kind: 'figure', number: 2 }]);
    expect(figureMentions('No figures here; configure 3 things')).toEqual([]);
  });
  it('matches a mention to the caption that names it', () => {
    const index = { figures: [{ id: 'b-1', block_id: 'b-1', asset_paths: ['a.png'], caption: 'Figure 2: The loss.', alt: '' },
      { id: 'b-2', block_id: 'b-2', asset_paths: ['b.png'], caption: 'Table 1. Results', alt: '' }] } as never;
    expect(figureFor({ kind: 'figure', number: 2 }, index)?.id).toBe('b-1');
    expect(figureFor({ kind: 'table', number: 1 }, index)?.id).toBe('b-2');
    expect(figureFor({ kind: 'figure', number: 1 }, index)).toBeUndefined();
  });
  it('keeps usable parts only, as the apps do', () => {
    const ok = { figure: 'F1', paragraph: 4, title: 'Pipeline', parts: [{ label: 'Encoder', box: [0, 0, 0.5, 1], note: 'Reads the input.' }] };
    expect(parseFigureParts(ok)?.parts).toHaveLength(1);
    expect(parseFigureParts({ ...ok, parts: [{ label: 'Sliver', box: [0, 0, 0.01, 1], note: 'Too thin.' }] })).toBeNull();
    expect(parseFigureParts({ ...ok, parts: [] })).toBeNull();
  });
  it('stores parts in the apps’ shape (sorted keys) and reads either encoding back', () => {
    const stored = { manifestSHA256: 'a'.repeat(64), blockID: 'b-9', assetPath: 'assets/x.png', paragraph: 9, title: 'Parts',
      parts: [{ label: 'One', box: [0, 0, 1, 0.5] as [number, number, number, number], note: 'Top.' }] };
    const text = storedFigurePartsText(stored);
    expect(Object.keys(JSON.parse(text))).toEqual(['assetPath', 'blockID', 'manifestSHA256', 'paragraph', 'parts', 'title']);
    expect(decodeStoredFigureParts(text)).toEqual(stored);
    // Swift's JSONEncoder escapes slashes.
    expect(decodeStoredFigureParts(text.replace('assets/x.png', 'assets\\/x.png'))?.assetPath).toBe('assets/x.png');
  });
  it('sends figures only with a paper question, never with Add paper', () => {
    const figure = { id: 'F1', paragraph: 3, caption: 'Figure 1: A.', mediaType: 'image/jpeg' as const, data: '/9j/'.padEnd(20, 'A'), width: 100, height: 80, blockID: 'b', assetPath: 'p' };
    const paper = { ...makeRequest('op', 'doc', [{ role: 'user', text: 'What does Figure 1 show?' }], null), figures: [figure] };
    expect(requestBody(paper).figures).toEqual([{ id: 'F1', paragraph: 3, caption: 'Figure 1: A.', media_type: 'image/jpeg', data: figure.data, width: 100, height: 80 }]);
    expect(requestBody(paper).consent_version).toBe('cloud-ai-v3');
    const general = { ...makeRequest('op', null, [{ role: 'user', text: 'Figure 1?' }], null), figures: [figure] };
    expect(requestBody(general).figures).toBeUndefined();
  });
});
