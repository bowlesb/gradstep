import { expect, it } from 'vitest';
import { FOLLOW_TOLERANCE_PX, TranscriptFollow, transcriptFollows } from '../src/lib/chat-follow';

it('only the end of the transcript follows new text', () => {
  expect(transcriptFollows(0)).toBe(true);
  expect(transcriptFollows(FOLLOW_TOLERANCE_PX)).toBe(true);
  expect(transcriptFollows(-1)).toBe(true); // overscroll rounding
  expect(transcriptFollows(3)).toBe(false); // one trackpad tick up stays put
  expect(transcriptFollows(79)).toBe(false); // the old 80 px band no longer re-follows
  expect(transcriptFollows(Number.NaN)).toBe(false);
});

it('a reader move between a follow scroll and its delayed event wins', () => {
  const follow = new TranscriptFollow();
  follow.programmatic(900);
  expect(follow.scrolled(740, 900)).toBe(false);
  expect(follow.mayFollow).toBe(false);
  expect(follow.scrolled(899, 900)).toBe(true); // the reader explicitly returns to the end
});

it('a held touch blocks follow before the first movement, including an old programmatic event', () => {
  const follow = new TranscriptFollow();
  follow.programmatic(900);
  follow.input(true);
  follow.scrolled(900, 900);
  expect(follow.mayFollow).toBe(false);
  follow.endInput(700, 940);
  expect(follow.mayFollow).toBe(false);
  follow.reset(); // Latest message or a different conversation
  expect(follow.mayFollow).toBe(true);
});

it('only the matching programmatic position is ignored', () => {
  const follow = new TranscriptFollow();
  follow.programmatic(900);
  expect(follow.scrolled(900, 930)).toBe(true); // content arrived after the position was set
  follow.input();
  expect(follow.scrolled(850, 930)).toBe(false);
});
