// The on-device PDF route (docs/architecture/DEVICE_PDF_ROUTE.md): the converter's own types and constants. The
// reference is the desktop's Python converter `src/gradstep/bundle/device_pdf.py` (converter 0.1.0, frozen
// 2026-10-14 as the "port kit"); every constant below carries the reference's name and value.

export const DEVICE_PDF_RENDERER_ID = 'gradstep-device-pdf-mathml-v1';
export const DEVICE_PDF_SOURCE_KIND = 'device-pdf';
export const DEVICE_PDF_PROVENANCE_FORMAT = 'device-pdf-reader-provenance-v1';
/** The reference converter's version this port follows (its block and equation id scheme hashes it). */
export const DEVICE_PDF_CONVERTER_VERSION = '0.1.0';
/** This port's own revision: bump whenever the output can change for the same inputs. */
export const DEVICE_PDF_PORT_REVISION = 19;

export const PLACEHOLDER = '￼';
export const DPI = 150;
export const CROP_SCALE = 3; // formula images at 3x the paper's own scale (216 dpi)
export const CROP_HALO = 1, CROP_MARGIN = 8; // recogniser crops as the factory cut the training crops
export const GATE = 0.8, GATE_DISPLAY = 0.95;
export const BLOCK_TEXT_CHUNK = 12_000;
export const MARGIN = 0.08;
export const EDGE_MARGIN = 0.5;
export const LINE_GAP = 1.0;
export const CELL_GAP = 0.6, WIDE_CELL = 0.4, TABLE_PLACED = 0.6;
export const FLOWISH = new Set(['title', 'abstract', 'heading', 'paragraph', 'listing', 'display', 'bibitem', 'footnote']);
/** Region classes whose lines the inline tagger reads (never inside the reference list or the author block). */
export const TAGGED = new Set(['paragraph', 'abstract', 'footnote', 'bibitem', 'caption', 'listing']);
export const LAYOUT_CLASSES = ['title', 'abstract', 'heading', 'paragraph', 'caption', 'footnote', 'bibitem', 'listing', 'display', 'table', 'figure'];

export type Box = [number, number, number, number];

/** One character of the PDF's text layer: points, top-left origin, in content-stream order. */
export interface Glyph { text: string; x0: number; top: number; x1: number; bottom: number; size: number; font: string; upright: boolean }

/** A layout region: `box` in 150 dpi page pixels, `pt` in points. */
export interface Region {
  cls: string; score: number; box: number[]; pt: Box;
  orphan?: boolean; parts?: Region[]; captions?: Region[];
}

export interface PageInput {
  width: number; height: number; image_width: number; image_height: number; scale: number;
  glyphs: { text: string[]; x0: number[]; top: number[]; x1: number[]; bottom: number[]; size: number[]; font: string[]; upright: (boolean | number)[] };
  detections: { cls: string; score: number; box: number[] }[];
}
export interface TagLine { x: number[]; font: number[]; cls: number[]; char: number[] }
/** `display`: the formula is a display (the host groups crops of like length into its batches). `cost`: the formula's glyph
 * count, which predicts the length of its reading better than the crop's width (the host batches like costs together). */
export interface RecogniseRequest { page: number; rect: [number, number, number, number]; display?: boolean; cost?: number }
/** `clean` (formula crops only): the formula's font size and the margin kept around its ink, in pixels at `dpi`; the host
 * drops the cut tails of neighbouring lines, trims to the ink and adds the margin (DevicePDFRaster.cleanFormula). */
export interface ImageRequest { page: number; dpi: number; rect: [number, number, number, number]; clean?: { em: number; margin: number } }
/** `rect`: where a cleaned image sits on the page, in pixels at the request's `dpi` (it may reach past the request's). */
export interface ImageResult { png: string; width: number; height: number; rect?: [number, number, number, number] }

/** The Swift host (JavaScriptCore) or a test double: every call is synchronous. */
export interface DevicePDFHost {
  page(index: number): PageInput;
  tag(lines: TagLine[]): number[][];
  recognise(crops: RecogniseRequest[]): ({ latex: string; probs: number[] } | null)[];
  /** Optional, together with `collect` (port revision 5): the host cuts the page's crops now and recognises them in the
   * background while the converter reads on; `collect` waits for that submission's results (same shape as `recognise`). */
  submit?(crops: RecogniseRequest[]): number;
  collect?(ticket: number): ({ latex: string; probs: number[] } | null)[];
  /** Optional: a complete bundle made before the formulas are read (each shown as its image), so the reader can show the
   * paper while the recogniser finishes; the same shape as `convert`'s result. */
  preview?(bundle: { manifest: string; manifest_sha256: string; members: Record<string, string>; summary: Record<string, unknown> }): void;
  image(request: ImageRequest): ImageResult;
  progress?(stage: string, done: number, total: number): void;
  cancelled?(): boolean;
}

export interface TaggerVocabulary {
  font_vocab: Record<string, number>; font_prior: Record<string, number>; char_vocab: Record<string, number>;
  threshold: number; max_len: number; unknown_index?: number; default_prior?: number;
  /** v5: neighboring glyphs on either side; two extra feature columns identify context. Absent/zero means v4. */
  context?: number;
}

export interface DevicePDFInput {
  pdf: { sha256: string; bytes: number; name: string };
  pages: number;
  /** The library's title for the paper: heads it when the layout finds no title. */
  title?: string;
  paper?: { source_id: string; revision: number };
  models: { role: string; id: string; sha256: string }[];
  tagger: TaggerVocabulary;
  /** Evaluation: also return the reference's own index.json shape for `bundle_conformance.py`. */
  trace?: boolean;
  /** Evaluation: also return what the host answered (device-pdf/record.ts), for the Node replay. */
  record?: boolean;
  /** Simple inline formulas written from the text layer instead of recognised (transcribe.ts). */
  transcribe?: boolean;
  /** The library's authors (names as listed): the first page's author lines are found by them (convert.frontMatterRoles). */
  authors?: string[];
  /** The first page's title and author lines found when the layout called them headings (convert.frontMatterRoles). */
  frontMatter?: boolean;
  /** A confident recognition Temml refuses is tidied and tried again (math.tidyLatex). */
  tidy?: boolean;
  /** Math the tagger missed (paragraph lines and table cells), found by its fonts (transcribe.mathRuns); with `transcribe`. */
  fontMath?: boolean;
  /** Tagged formulas grown over the digits, operators and operator names the tagger cut off (convert.extendSpans). */
  extendSpans?: boolean;
  /** A text line's run belongs to the region holding most of it (convert.lineOwners). */
  lineOwners?: boolean;
  /** No heading twice: the library's title, "ABSTRACT", a printed contents list (convert.contentsAsText). */
  headingDupes?: boolean;
  /** A references region holding several entries read as its entries (convert.referenceEntries). */
  splitReferences?: boolean;
  /** Figure and table captions keep their math as marked text (tagged and font-found formulas), as paragraphs do. */
  captionMath?: boolean;
  /** A bibliography without a heading read as references, overlapping entry boxes merged, entries continued across regions. */
  bibliography?: boolean;
  /** A display's equation number ("(12)", set apart at its right) is left out of the recogniser's crop and shown as the
   * equation's tag (convert.equationNumber). */
  equationNumbers?: boolean;
  /** Overlapping display boxes (a group and its rows) read as one display (convert.mergeOverlapping). */
  mergeDisplays?: boolean;
  /** The venue's notice on the first page (proceedings line, copyright, open-access watermark) left out (structure.venueNotice). */
  venueNotice?: boolean;
  /** A display's full stop or comma set just outside its box is added to its LaTeX (convert.trailingPunctuation). */
  displayPunctuation?: boolean;
  /** Fonts the tagger does not know read as the ones they stand for (tagger.aliasFont). */
  fontAliases?: boolean;
  /** A tightly set line's word gaps from its own letter spacing (geometry.lineText). */
  wordGaps?: boolean;
  /** TeX's text accents composed with their letters (geometry.composeAccents). */
  accents?: boolean;
  /** Lines need a third of a glyph's height in common to join (geometry.linesOf). */
  lineBands?: boolean;
  /** The display gate's threshold (second-lowest token probability) instead of GATE_DISPLAY; 0.5 to 1. */
  displayGate?: number;
  /** A formula whose glyphs repeat an earlier formula's exactly (characters, fonts, sizes, places within its box) takes
   * that formula's recognition instead of being recognised again (speed; convert.formulaSignature). */
  reuseRecognitions?: boolean;
  /** Displays the layout read as lines of a paragraph (numbered at the right margin, or indented on both sides and nearly
   * all math) become display regions (convert.displayLines). */
  displayLines?: boolean;
  /** A recognition under the confidence gate is typeset when its letters and digits are the PDF's own glyphs (the same
   * characters, as many of each) and its confidence is at least this (0 to 1; math.glyphsAgree). */
  verifyGlyphs?: boolean | number;
  /** Ligature glyphs (ﬁ, ﬂ, ﬀ, ﬃ, ﬄ) written as their letters in text (geometry.lineText). */
  ligatures?: boolean;
  /** A hyphen at a line's end is kept when the paper shows it is the word's own ("three-dimensional"), dropped when it is
   * TeX's hyphenation (geometry.joinLines). */
  compounds?: boolean;
  /** A glyph returning to the left below its line's own text starts a new line, whatever its scripts widened (linesOf). */
  lineReturns?: boolean;
  /** Table columns from the lines with the most cells (tables.TableOptions.columns). */
  tableColumns?: boolean;
  /** A table cell of several lines read line by line (tables.TableOptions.cellLines). */
  cellLines?: boolean;
  /** Table cells separated by gaps of 0.45 glyph heights, not 0.6 (tables.TableOptions.narrowGaps). */
  narrowCellGaps?: boolean;
  /** A table's caption printed under it follows the table in the reading (convert, emit). */
  tableCaptionBelow?: boolean;
}

export interface Formula {
  id: string; display: boolean; page: number; box: Box; baseline?: number;
  /** The median glyph size of the line (inline) or of the display's glyphs: sizes the formula's image in em. */
  fontSize: number;
  /** The formula's own characters, kept for the equation limit's plain-text fallback. */
  glyphText: string;
  latex: string; confidence: number; probs?: number[]; recognised: boolean;
  /** Written from the text layer (transcribe.ts), not read by the recogniser. */
  transcribed?: boolean;
  /** The glyphs' signature (reuseRecognitions): equal signatures crop to the same picture. */
  signature?: string;
  /** The characters of its glyphs on the page (verifyGlyphs). */
  glyphTexts?: string[];
  rendered: boolean; mathml?: unknown; image?: { path: string; width: number; height: number };
  /** A display's equation number, read from the text layer (equationNumbers) and left out of `box`. */
  tag?: string;
  /** Where the formula's image is cut when it differs from `box` (the display with its number). */
  imageBox?: Box;
  /** The punctuation after a display, outside its box (displayPunctuation). */
  trailing?: string;
}
