import { expect, it } from 'vitest';
import { MAXIMUM_READER_HEADINGS, type VerifiedBundle } from '../src/lib/bundle';
import { readFrameMessage, referenceLink } from '../src/reader/frame';

it('admits the contents of the largest supported reader profile and refuses larger messages', () => {
  const items = Array.from({ length: MAXIMUM_READER_HEADINGS }, (_, i) => ({ id: `b-heading-${i}`, title: `Section ${i + 1}` }));
  expect(items.length).toBe(1000); // Mathpix supports more headings than the older authored profile.
  expect(readFrameMessage({ type: 'headings', items })).toEqual({ type: 'headings', items });
  expect(readFrameMessage({ type: 'headings', items: [...items, { id: 'excess', title: 'Excess' }] })).toBeNull();
});

it('selection actions require a bounded, exact manifest with IDs instead of formula markup', () => {
  const manifest = 'a'.repeat(64);
  const selection = { manifest_sha256: manifest, parts: [{ kind: 'equation', block_id: 'b-1', equation_id: 'e-1' }], context: { prefix: 'before', suffix: 'after' } };
  expect(readFrameMessage({ type: 'selection', selection })).toMatchObject({ selection: { manifest, parts: [{ kind: 'equation', blockID: 'b-1', equationID: 'e-1' }] } });
  expect(readFrameMessage({ type: 'selection', selection: { ...selection, parts: [{ ...selection.parts[0], text: '<math>forged</math>' }] } })).toMatchObject({ selection: null });
  expect(readFrameMessage({ type: 'selection', selection: { ...selection, manifest_sha256: 'unknown' } })).toMatchObject({ selection: null });
  expect(readFrameMessage({ type: 'marks', ids: ['not-a-chat'] })).toBeNull();
});

const bound = { manifestSHA256: 'a'.repeat(64), index: { blocks: [
  { id: 'b-ref', kind: 'paragraph', text: 'Reference' }, { id: 'b-table', kind: 'table', text: 'Table' }, { id: 'b-code', kind: 'code', text: 'Algorithm' },
], figures: [{ id: 'b-figure' }] } } as VerifiedBundle;
const reference = { type: 'reference', manifest_sha256: bound.manifestSHA256, block_id: 'b-ref', text: '  Author.\n arXiv: 2305.18290v3. ', links: [], rect: { x: 10, y: 20, width: 50, height: 30 } };
it('reference actions bind to the exact verified paper and bounded block text', () => {
  expect(readFrameMessage(reference, bound)).toMatchObject({ type: 'reference', reference: { blockID: 'b-ref', text: 'Author. arXiv: 2305.18290v3.', link: { url: 'https://arxiv.org/abs/2305.18290v3' } } });
  expect(readFrameMessage(reference)).toBeNull();
  for (const change of [{ manifest_sha256: 'b'.repeat(64) }, { block_id: 'unknown' }, { text: ' ' }, { text: '😀'.repeat(4001) }]) expect(readFrameMessage({ ...reference, ...change }, bound)).toBeNull();
  expect(readFrameMessage({ ...reference, rect: { x: Infinity, y: 0, width: 3, height: 3 } }, bound)).toMatchObject({ reference: { rect: null } });
});
it('figure references admit only verified figures, tables or code, with a bounded native label', () => {
  for (const [id, label, goTitle] of [['b-figure', 'Figure 3', 'Go to figure'], ['b-table', 'Table A.1', 'Go to table'], ['b-code', 'Algorithm 1', 'Go to algorithm']]) {
    expect(readFrameMessage({ type: 'figureref', manifest_sha256: bound.manifestSHA256, id, label }, bound)).toEqual({ type: 'figureref', reference: { id, label, goTitle } });
  }
  for (const change of [{ id: 'b-ref' }, { id: 'unknown' }, { label: 'Figure <script>' }, { manifest_sha256: 'b'.repeat(64) }]) {
    expect(readFrameMessage({ type: 'figureref', manifest_sha256: bound.manifestSHA256, id: 'b-figure', label: 'Figure 1', ...change }, bound)).toBeNull();
  }
});
it('reference destinations prefer arXiv and DOI without enabling credentials or active URL schemes', () => {
  expect(referenceLink('CoRR abs/2401.12345.', ['https://example.test/'])).toEqual({ url: 'https://arxiv.org/abs/2401.12345', title: 'Open on arXiv' });
  expect(referenceLink('doi: 10.1000/example(foo)).', [])).toEqual({ url: 'https://doi.org/10.1000/example(foo)', title: 'Open DOI' });
  expect(referenceLink('arXiv: 2399.12345', [])).toBeNull();
  expect(referenceLink('A title', ['javascript:alert(1)', 'http://example.test', 'https://user:password@example.test'])).toBeNull();
  expect(referenceLink('A title', ['https://example.test/paper'])).toEqual({ url: 'https://example.test/paper', title: 'Open link' });
});

it('Back after a jump: offered unless the bridge says not, with the section it returns to (bounded)', () => {
  expect(readFrameMessage({ type: 'citation', state: 'jumped', back: true, from: '3  Method\n' })).toEqual({ type: 'citation', state: 'jumped', back: true, from: '3 Method' });
  // A chat jump that began at the top offers no Back.
  expect(readFrameMessage({ type: 'citation', state: 'jumped', id: 'passage', back: false, from: '' })).toMatchObject({ back: false });
  // An older bridge names neither: Back with no section.
  expect(readFrameMessage({ type: 'citation', state: 'jumped' })).toEqual({ type: 'citation', state: 'jumped', back: true, from: '' });
  expect(readFrameMessage({ type: 'citation', state: 'ended', back: true })).toMatchObject({ back: false });
  expect((readFrameMessage({ type: 'citation', state: 'jumped', from: 'x'.repeat(200) }) as { from: string }).from).toHaveLength(60);
  expect(readFrameMessage({ type: 'citation', state: 'other' })).toBeNull();
});
