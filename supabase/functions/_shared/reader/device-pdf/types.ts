// The on-device PDF route (docs/architecture/DEVICE_PDF_ROUTE.md): the converter's own types and constants. The
// reference is the desktop's Python converter `src/gradstep/bundle/device_pdf.py` (converter 0.1.0, frozen
// 2026-10-14 as the "port kit"); every constant below carries the reference's name and value.

export const DEVICE_PDF_RENDERER_ID = 'gradstep-device-pdf-mathml-v1';
export const DEVICE_PDF_SOURCE_KIND = 'device-pdf';
export const DEVICE_PDF_PROVENANCE_FORMAT = 'device-pdf-reader-provenance-v1';
/** The reference converter's version this port follows (its block and equation id scheme hashes it). */
export const DEVICE_PDF_CONVERTER_VERSION = '0.1.0';
/** This port's own revision: bump whenever the output can change for the same inputs. */
export const DEVICE_PDF_PORT_REVISION = 2;

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
export interface RecogniseRequest { page: number; rect: [number, number, number, number] }
export interface ImageRequest { page: number; dpi: number; rect: [number, number, number, number] }
export interface ImageResult { png: string; width: number; height: number }

/** The Swift host (JavaScriptCore) or a test double: every call is synchronous. */
export interface DevicePDFHost {
  page(index: number): PageInput;
  tag(lines: TagLine[]): number[][];
  recognise(crops: RecogniseRequest[]): ({ latex: string; probs: number[] } | null)[];
  image(request: ImageRequest): ImageResult;
  progress?(stage: string, done: number, total: number): void;
  cancelled?(): boolean;
}

export interface TaggerVocabulary {
  font_vocab: Record<string, number>; font_prior: Record<string, number>; char_vocab: Record<string, number>;
  threshold: number; max_len: number; unknown_index?: number; default_prior?: number;
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
}

export interface Formula {
  id: string; display: boolean; page: number; box: Box; baseline?: number;
  /** The median glyph size of the line (inline) or of the display's glyphs: sizes the formula's image in em. */
  fontSize: number;
  /** The formula's own characters, kept for the equation limit's plain-text fallback. */
  glyphText: string;
  latex: string; confidence: number; probs?: number[]; recognised: boolean;
  rendered: boolean; mathml?: unknown; image?: { path: string; width: number; height: number };
}
