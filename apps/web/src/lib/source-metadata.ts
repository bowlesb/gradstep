// Device-read paper metadata in the browser (docs/architecture/ARXIV_DEVICE_ONLY.md §5.2–5.3, §5.9). Owner direction,
// 2026-10-15: our servers never contact arXiv. While the server's `source_metadata` capability is on, the page this
// browser already downloaded to prepare a paper is read for its title, authors, abstract, licence and version date
// (the same extractor the apps run) and sent for the paper's import, once per import and version; nothing is stored
// here. A version arXiv has no HTML for sends nothing from the browser: arXiv's own API sends no CORS headers, and the
// DataCite alternative waits for the owner (ARXIV_DEVICE_ONLY.md §5.10). The extractor loads only when first
// needed, so a browser with the capability off never loads it.
import { rpc } from './backend';
import { fromUtf8, type Bytes } from './bytes';
import type { ArxivSourceObserver } from './arxiv-reader';
import type { SourcePaperReference } from './events';

export const SOURCE_METADATA_FORMAT = 'arxiv-source-metadata-v1';
const CAPABILITY_TTL_MS = 10 * 60 * 1000;

export interface SourceMetadataDeps {
  capabilities(account: string): Promise<{ source_metadata?: { enabled?: unknown; format?: unknown } } | null>;
  submit(account: string, importID: string, metadata: unknown, revision: number): Promise<unknown>;
  now?: () => number;
}

const live: SourceMetadataDeps = {
  capabilities: account => rpc('v1_reader_capabilities', {}, { account, maximum: 16_384 }),
  submit: (account, importID, metadata, revision) => rpc('v1_submit_source_metadata',
    { p_import_id: importID, p_metadata: metadata, p_expected_revision: revision }, { account, maximum: 1_024 }),
};

/** The observer for one signed-in account (`observeArxivSources`). */
export function sourceMetadataReporter(account: string, deps: SourceMetadataDeps = live): ArxivSourceObserver & { settled(): Promise<void> } {
  const now = deps.now ?? (() => Date.now());
  const sent = new Set<string>();
  let capability: { enabled: boolean; at: number } | null = null;
  const pending = new Set<Promise<unknown>>();
  const key = (ref: SourcePaperReference) => `${ref.membershipID}|${ref.sourceID}v${ref.revision}`;

  async function enabled(): Promise<boolean> {
    if (capability && now() - capability.at < CAPABILITY_TTL_MS) return capability.enabled;
    let on = false;
    try { const caps = await deps.capabilities(account); on = caps?.source_metadata?.enabled === true && caps.source_metadata.format === SOURCE_METADATA_FORMAT; }
    catch { on = false; }
    capability = { enabled: on, at: now() };
    return on;
  }

  return {
    source(ref, html: Bytes) {
      if (sent.has(key(ref))) return;
      const work = (async () => {
        if (!await enabled()) return;
        const { extractSourceMetadata } = await import('../../../../supabase/functions/_shared/reader/arxiv/source-metadata.ts');
        let text: string; try { text = fromUtf8(html); } catch { return; }
        const metadata = extractSourceMetadata(text, ref.sourceID, ref.revision)?.metadata;
        if (!metadata || sent.has(key(ref))) return;
        try { await deps.submit(account, ref.membershipID, metadata, ref.revision); sent.add(key(ref)); } catch { /* tried again the next time it is prepared */ }
      })();
      pending.add(work); void work.finally(() => pending.delete(work));
    },
    /** Tests: wait for every report started so far. */
    async settled() { while (pending.size) await Promise.allSettled([...pending]); },
  };
}
