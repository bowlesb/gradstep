// The completeness step and framing where parts are shown (figure-crops.ts, figure-framing.ts; FIGURE_VIEW.md "Complete
// crops", "Parts as viewports"): the ink of the image a request carried, found once per image and kept for a few images,
// and each card's framing. Until the ink is
// known a card shows no crop (no crop that then changes size); when it can't be found, the AI's own box is shown.
import { useEffect, useMemo, useState } from 'react';
import { prepareFigure } from '../lib/chat-figures';
import { base64Blob, inkOf, type FigureInk } from '../lib/figure-crops';
import { frameParts, type FramedPart, type FramingInput } from '../lib/figure-framing';

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

/** Every part of one set framed (figure-framing.ts: completion, then confidence and its frame) once the ink is known
 * (undefined until then, so no card shows and then changes size). Without the ink (it couldn't be found), the AI's boxes
 * unchecked: framed loosely and outlined. */
export function useFramedParts(ink: FigureInk | null | undefined, image: { width: number; height: number } | null, input: FramingInput):
  { parts: FramedPart[]; coverage: number | null } | undefined {
  const key = JSON.stringify([input.boxes, input.caption ?? '', input.labels ?? [], input.detector ?? null, input.exact ?? null, input.structureParts ?? 0, image?.width, image?.height]);
  return useMemo(() => ink === undefined || (!ink && !image) ? undefined : frameParts(ink, ink ?? image!, input), [ink, key]); // eslint-disable-line react-hooks/exhaustive-deps
}
