// The text column's measure (READING_MODE.md), on its own so the app's chrome can offer it without loading the reader
// frame (C5: the frame script is in the reader's own chunk).
export type LineWidth = 'comfortable' | 'wide' | 'full';
export const LINE_WIDTHS: readonly LineWidth[] = ['comfortable', 'wide', 'full'];
