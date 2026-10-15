// Figures in chat (docs/proposals/CHAT_TOOLS.md item 4): a question about a figure carries that figure's image from
// the paper the device prepared (arXiv's own figure, re-encoded on the device), so the model reads the figure itself,
// and the model may break it into parts the device crops and shows with an explanation each. Sent only under consent
// cloud-ai-v3, which names figures. Nothing here is stored: the images pass through to the provider like the text.
import type Anthropic from '@anthropic-ai/sdk';

export const FIGURE_LIMITS = Object.freeze({ images: 3, base64Chars: 1_600_000, totalBase64Chars: 3_200_000, maxSide: 1_600, captionChars: 1_200 });
/** Hold per attached image: Anthropic bills about (width × height) / 750 tokens after resizing to about 1.15 MP. */
export const IMAGE_HOLD_TOKENS = 1_600;

export interface FigureImage { id: string; paragraph: number; caption: string; mediaType: 'image/jpeg' | 'image/png'; data: string; width: number; height: number }

const invalid = (): never => { throw new Error('invalid_figures'); };

/** The request's `figures`, validated: at most three images, ids F1–F3, a paragraph number, bounded base64 PNG/JPEG. */
export function figureImages(value: unknown): FigureImage[] {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value) || value.length > FIGURE_LIMITS.images) invalid();
  let total = 0;
  const seen = new Set<string>();
  return (value as unknown[]).map(item => {
    if (!item || typeof item !== 'object' || Array.isArray(item)) invalid();
    const v = item as Record<string, unknown>;
    if (Object.keys(v).some(key => !['id', 'paragraph', 'caption', 'media_type', 'data', 'width', 'height'].includes(key))) invalid();
    const id = v.id, paragraph = v.paragraph, caption = v.caption ?? '', mediaType = v.media_type, data = v.data, width = v.width, height = v.height;
    if (typeof id !== 'string' || !/^F[1-3]$/.test(id) || seen.has(id)) invalid();
    seen.add(id as string);
    if (!Number.isSafeInteger(paragraph) || (paragraph as number) < 1 || (paragraph as number) > 20_000) invalid();
    if (typeof caption !== 'string' || [...caption].length > FIGURE_LIMITS.captionChars) invalid();
    if (mediaType !== 'image/jpeg' && mediaType !== 'image/png') invalid();
    if (typeof data !== 'string' || data.length < 16 || data.length > FIGURE_LIMITS.base64Chars || !/^[A-Za-z0-9+/]+={0,2}$/.test(data)) invalid();
    total += (data as string).length; if (total > FIGURE_LIMITS.totalBase64Chars) invalid();
    for (const side of [width, height]) if (!Number.isSafeInteger(side) || (side as number) < 8 || (side as number) > FIGURE_LIMITS.maxSide) invalid();
    // The bytes are what they say: a JPEG starts FF D8, a PNG with its signature.
    const head = atob((data as string).slice(0, 16));
    const jpeg = head.charCodeAt(0) === 0xff && head.charCodeAt(1) === 0xd8, png = head.startsWith('\u0089PNG');
    if ((mediaType === 'image/jpeg' && !jpeg) || (mediaType === 'image/png' && !png)) invalid();
    return { id: id as string, paragraph: paragraph as number, caption: (caption as string).replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim(),
      mediaType: mediaType as FigureImage['mediaType'], data: data as string, width: width as number, height: height as number };
  });
}

/** The blocks that go before the question: each figure's label (its paragraph number and caption), then its image. */
export function figureBlocks(images: readonly FigureImage[]): Anthropic.Beta.Messages.BetaContentBlockParam[] {
  return images.flatMap(image => [
    { type: 'text' as const, text: `<figure id="${image.id}" paragraph="¶${image.paragraph}">${image.caption.replace(/[<>]/g, ' ')}</figure>` },
    { type: 'image' as const, source: { type: 'base64' as const, media_type: image.mediaType, data: image.data } },
  ]);
}

export const SHOW_FIGURE_PARTS_TOOL: Anthropic.Beta.Messages.BetaTool = {
  name: 'show_figure_parts',
  description: 'Breaks a figure attached to the question into its parts: the reader sees each part cropped from the figure with your '
    + 'note beside it. Use it only when a figure is attached (F1, F2…) and it has distinct parts worth reading one by one: panels, '
    + 'stages of a pipeline, blocks of an architecture, regions of a plot, the legend. Boxes are fractions of the image: [left, top, '
    + 'right, bottom], each from 0 to 1, tight around one part. 2 to 8 parts in reading order. Call it at most once, after your text; '
    + 'never also call create_visual or create_diagram in the same answer.',
  input_schema: {
    type: 'object',
    properties: {
      figure: { type: 'string', description: 'The attached figure id, e.g. "F1".' },
      title: { type: 'string', description: 'A short title (under 80 characters).' },
      parts: { type: 'array', minItems: 1, maxItems: 8, items: { type: 'object', properties: {
        label: { type: 'string', description: 'A short name for the part (under 40 characters).' },
        box: { type: 'array', items: { type: 'number' }, minItems: 4, maxItems: 4, description: '[left, top, right, bottom], fractions of the image.' },
        note: { type: 'string', description: 'What this part shows and how to read it, in one to three sentences.' },
      }, required: ['label', 'box', 'note'] } },
    },
    required: ['figure', 'title', 'parts'],
  },
};

export interface FigurePart { label: string; box: [number, number, number, number]; note: string }
export interface FigureParts { figure: string; paragraph: number; title: string; parts: FigurePart[] }

const clean = (value: unknown, limit: number): string | null => {
  if (typeof value !== 'string') return null;
  const text = value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  return text && [...text].length <= limit ? text : null;
};

/** The model asks for a figure the question is about when none is attached (owner, 2026-10-15: "break down the most
 * complex figure" and "Figure 4" asked of a build without figures both got a caption-only answer). The device finds
 * the figure in its copy of the paper and asks again with it attached; offered only to devices that say they can
 * (`figure_requests`), under consent v3, so an older build is never left with an unanswered request. */
export const LOOK_AT_FIGURE_TOOL: Anthropic.Beta.Messages.BetaTool = {
  name: 'look_at_figure',
  description: 'Gets the image of one figure or table of this paper from the reader\'s device. Use it when the question is about a '
    + 'figure or table (named, or one you choose, such as "the most complex figure") and no figure is attached (no F1). Name it as '
    + 'its caption numbers it: "Figure 4" or "Table 2". Call it first, before writing anything else: the device sends the question '
    + 'again with that image attached, and you answer then. Never call it when a figure is attached.',
  input_schema: {
    type: 'object',
    properties: { figure: { type: 'string', description: 'The figure or table as its caption numbers it, e.g. "Figure 4" or "Table 2".' } },
    required: ['figure'],
  },
};

/** The look_at_figure input as the device finds it ("Figure 4", "Table 2"), or null. */
export function figureLookRequest(input: unknown): { figure: string } | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const m = /^\s*(figure|fig\.?|table)\s*(\d{1,3})\s*$/i.exec(String((input as Record<string, unknown>).figure ?? ''));
  return m ? { figure: `${m[1].toLowerCase().startsWith('tab') ? 'Table' : 'Figure'} ${Number(m[2])}` } : null;
}

/** Validates the model's show_figure_parts input against the figures that were attached. */
export function figurePartsRequest(input: unknown, images: readonly FigureImage[]): FigureParts | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const v = input as Record<string, unknown>;
  const image = images.find(i => i.id === v.figure);
  const title = clean(v.title, 120);
  if (!image || !title || !Array.isArray(v.parts) || v.parts.length < 1 || v.parts.length > 8) return null;
  const parts: FigurePart[] = [];
  for (const raw of v.parts as unknown[]) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
    const p = raw as Record<string, unknown>;
    const label = clean(p.label, 60), note = clean(p.note, 800);
    if (!label || !note || !Array.isArray(p.box) || p.box.length !== 4) return null;
    const box = (p.box as unknown[]).map(n => typeof n === 'number' && Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : NaN);
    if (box.some(Number.isNaN) || box[2] - box[0] < 0.03 || box[3] - box[1] < 0.03) return null;
    parts.push({ label, note, box: box.map(n => Math.round(n * 10_000) / 10_000) as FigurePart['box'] });
  }
  return { figure: image.id, paragraph: image.paragraph, title, parts };
}

/** After the paper, with the question's figures: read the image itself; break it into parts when that helps. */
export function figureInstructions(images: readonly FigureImage[], parts: boolean, look = false): string | null {
  if (!images.length) {
    return look ? 'No figure is attached to this question. When it is about a figure or table of the paper, by its number or by a '
      + 'description ("the architecture figure", "the most complex figure"), choose it from the captions in the paper and call '
      + 'look_at_figure with its number before writing anything; you will answer with its image.' : null;
  }
  return `The reader's question comes with the figure${images.length > 1 ? 's' : ''} it refers to, attached as image${images.length > 1 ? 's' : ''} `
    + `(${images.map(i => i.id).join(', ')}) with ${images.length > 1 ? 'their captions and paragraph numbers' : 'its caption and paragraph number'}. `
    + 'Read the image itself: axes, legends, panels, arrows, labels and values; say what the figure shows, not only what the caption says, and '
    + 'cite the figure by its paragraph number.'
    + (parts ? ' Write your explanation first, complete on its own: the figure\'s overall message and how its parts fit together. Then, '
      + 'when the figure has distinct parts worth reading one by one, call show_figure_parts once; the reader sees each part cropped '
      + 'beside your text, with your note.' : '');
}
