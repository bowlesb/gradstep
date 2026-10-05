// Bridges the pipeline's render stage to the Edge reader renderer.
import type { RenderedBundle, RenderInput } from './pipeline.ts';
import { renderMathpixReader } from './reader/index.ts';

export async function renderReader(input: RenderInput): Promise<RenderedBundle> {
  const bundle = await renderMathpixReader({ archive: input.archive, provenance: input.provenance,
    attribution: input.attribution, titleFallback: input.titleFallback });
  return { manifestBytes: bundle.manifestBytes, manifestSHA256: bundle.manifestSHA256, members: bundle.members };
}
