import { expect, it } from 'vitest';
import { MAXIMUM_READER_HEADINGS } from '../src/lib/bundle';
import { readFrameMessage } from '../src/reader/frame';

it('admits the contents of the largest supported reader profile and refuses larger messages', () => {
  const items = Array.from({ length: MAXIMUM_READER_HEADINGS }, (_, i) => ({ id: `b-heading-${i}`, title: `Section ${i + 1}` }));
  expect(items.length).toBe(1000); // Mathpix supports more headings than the older authored profile.
  expect(readFrameMessage({ type: 'headings', items })).toEqual({ type: 'headings', items });
  expect(readFrameMessage({ type: 'headings', items: [...items, { id: 'excess', title: 'Excess' }] })).toBeNull();
});
