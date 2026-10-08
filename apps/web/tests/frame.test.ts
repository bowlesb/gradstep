import { expect, it } from 'vitest';
import { MAXIMUM_READER_HEADINGS } from '../src/lib/bundle';
import { readFrameMessage } from '../src/reader/frame';

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
