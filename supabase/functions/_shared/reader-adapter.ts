// Bridges the pipeline's render stage to the Edge reader renderer.
import type { RenderedBundle, RenderInput } from './pipeline.ts';

export async function renderReader(_input: RenderInput): Promise<RenderedBundle> {
  throw new Error('renderer_unavailable');
}
