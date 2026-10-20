/** Whether the transcript follows new text after the reader's own scroll, from their distance to its end in CSS
 * pixels. Only being at the end (a pixel or two of rounding) follows: any scroll away from it, however small, is the
 * reader's choice to stay where they are while an answer streams (owner report, build 35). */
export const FOLLOW_TOLERANCE_PX = 2;
export function transcriptFollows(distanceToEnd: number): boolean {
  return Number.isFinite(distanceToEnd) && distanceToEnd <= FOLLOW_TOLERANCE_PX;
}

/** A follow scroll can report its event after the reader has already moved. Ignore only a matching
 * position, never an arbitrary "next" event. Input takes ownership before incoming text can follow again. */
export class TranscriptFollow {
  following = true;
  private expectedTop: number | null = null;
  private holding = false;
  get isHolding() { return this.holding; }
  get mayFollow() { return this.following && !this.holding; }
  reset() { this.following = true; this.expectedTop = null; this.holding = false; }
  input(held = false) { this.following = false; this.expectedTop = null; this.holding ||= held; }
  endInput(top: number, maximum: number) { this.holding = false; return this.scrolled(top, maximum); }
  programmatic(top: number) { this.expectedTop = top; }
  scrolled(top: number, maximum: number) {
    const own = this.expectedTop !== null && Math.abs(top - this.expectedTop) <= 1;
    this.expectedTop = null;
    if (!own) this.following = transcriptFollows(maximum - top);
    return this.following;
  }
}
