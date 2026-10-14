/** Whether the transcript follows new text after the reader's own scroll, from their distance to its end in CSS
 * pixels. Only being at the end (a pixel or two of rounding) follows: any scroll away from it, however small, is the
 * reader's choice to stay where they are while an answer streams (owner report, build 35). */
export const FOLLOW_TOLERANCE_PX = 2;
export function transcriptFollows(distanceToEnd: number): boolean {
  return Number.isFinite(distanceToEnd) && distanceToEnd <= FOLLOW_TOLERANCE_PX;
}
