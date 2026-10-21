// The completeness step where crops are shown (figure-crops.ts; FIGURE_VIEW.md "Complete crops"): the ink of the image
// a request carried, found once per image and kept for a few images, and each card's completed crop. Until the ink is
// known a card shows no crop (no crop that then changes size); when it can't be found, the AI's own box is shown.
import { useEffect, useMemo, useState } from 'react';
import { prepareFigure } from '../lib/chat-figures';
import { base64Blob, completeCrops, inkOf, presented, type FigureInk, type PresentedCrop, type Rect } from '../lib/figure-crops';

const kept = new Map<string, Promise<FigureInk | null>>();
function remember(key: string, make: () => Promise<FigureInk | null>): Promise<FigureInk | null> {
  let found = kept.get(key);
  if (!found) {
    found = make(); kept.set(key, found);
    while (kept.size > 6) kept.delete(kept.keys().next().value!);
  }
  return found;
}

/** The ink of a sent image (base64 JPEG): undefined while it is found, null when it can't be. */
export function useSentInk(data: string | null | undefined): FigureInk | null | undefined {
  const [ink, setInk] = useState<{ data: string; ink: FigureInk | null } | null>(null);
  useEffect(() => {
    if (!data) return;
    let live = true;
    void remember(`sent:${data.length}:${data.slice(0, 64)}:${data.slice(-64)}`, () => inkOf(base64Blob(data))).then(found => { if (live) setInk({ data, ink: found }); });
    return () => { live = false; };
  }, [data]);
  return !data ? null : ink?.data === data ? ink.ink : undefined;
}

/** The ink of a figure as a question carried it, from the paper's own image on this device (prepared again exactly as it
 * was sent: chat-figures.ts `prepareFigure`). */
export function useFigureBlobInk(image: Blob | null): FigureInk | null | undefined {
  const [ink, setInk] = useState<{ image: Blob; ink: FigureInk | null } | null>(null);
  useEffect(() => {
    if (!image) return;
    let live = true;
    void (async () => {
      const bytes = new Uint8Array(await image.arrayBuffer());
      let hash = 0; for (let i = 0; i < bytes.length; i += 97) hash = (hash * 31 + bytes[i]) | 0;
      const found = await remember(`blob:${bytes.length}:${hash}`, async () => {
        const sent = await prepareFigure(bytes, image.type || 'image/png');
        return sent ? inkOf(base64Blob(sent.data)) : null;
      });
      if (live) setInk({ image, ink: found });
    })().catch(() => { if (live) setInk({ image, ink: null }); });
    return () => { live = false; };
  }, [image]);
  return !image ? null : ink?.image === image ? ink.ink : undefined;
}

/** Each box's completed crop (boxes that belong together in one call, so they are completed against each other), with
 * the share of the figure's ink the crops show. Without the ink (it couldn't be found), the AI's own boxes with the
 * earlier 2 % of context, padded as any crop, and no coverage. */
export function completedFor(ink: FigureInk | null, boxes: Rect[]): { crops: PresentedCrop[]; coverage: number | null } {
  if (!boxes.length) return { crops: [], coverage: null };
  if (!ink) return { crops: boxes.map(b => ({ region: [Math.max(0, b[0] - 0.02), Math.max(0, b[1] - 0.02), Math.min(1, b[2] + 0.02), Math.min(1, b[3] + 0.02)] as Rect,
    whole: false, padX: 0.01, padY: 0.01 })), coverage: null };
  const done = completeCrops(ink, boxes);
  return { crops: done.crops.map(c => presented(ink, c)), coverage: done.coverage };
}

/** `completedFor` once the ink is known (undefined until then, so no crop shows and then changes size). */
export function useCompletedCrops(ink: FigureInk | null | undefined, boxes: Rect[]): { crops: PresentedCrop[]; coverage: number | null } | undefined {
  const key = JSON.stringify(boxes);
  return useMemo(() => ink === undefined ? undefined : completedFor(ink, boxes), [ink, key]); // eslint-disable-line react-hooks/exhaustive-deps
}
