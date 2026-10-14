import { expect, it } from 'vitest';
import { FOLLOW_TOLERANCE_PX, transcriptFollows } from '../src/lib/chat-follow';

it('only the end of the transcript follows new text', () => {
  expect(transcriptFollows(0)).toBe(true);
  expect(transcriptFollows(FOLLOW_TOLERANCE_PX)).toBe(true);
  expect(transcriptFollows(-1)).toBe(true); // overscroll rounding
  expect(transcriptFollows(3)).toBe(false); // one trackpad tick up stays put
  expect(transcriptFollows(79)).toBe(false); // the old 80 px band no longer re-follows
  expect(transcriptFollows(Number.NaN)).toBe(false);
});
