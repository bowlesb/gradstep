import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { sourceMetadataReporter, type SourceMetadataDeps } from '../src/lib/source-metadata';
import type { SourcePaperReference } from '../src/lib/events';

// Device-read paper metadata in the browser (docs/architecture/ARXIV_DEVICE_ONLY.md §5.3, §5.9): only while the server
// asks, once per import and version, from the page the browser already downloaded; nothing else is fetched.
const dpoPage = new TextEncoder().encode(readFileSync(new URL('../../../tests/backend/fixtures/arxiv-html/2305.18290v3-front.html', import.meta.url), 'utf8'));
const ref = (membershipID: string, sourceID = '2305.18290', revision = 3): SourcePaperReference =>
  ({ format: 'source-membership-v1', membershipID, source: 'arxiv', sourceID, revision });

function harness(enabled: boolean | 'v2', failures = 0) {
  const submitted: { importID: string; metadata: { origin: string; title: string; revision: number }; revision: number }[] = [];
  let capabilityCalls = 0, remainingFailures = failures;
  const deps: SourceMetadataDeps = {
    capabilities: async () => { capabilityCalls++; return { source_metadata: { enabled: enabled !== false, format: enabled === 'v2' ? 'arxiv-source-metadata-v2' : 'arxiv-source-metadata-v1' } }; },
    submit: async (_account, importID, metadata, revision) => {
      if (remainingFailures-- > 0) throw new Error('offline');
      submitted.push({ importID, metadata: metadata as never, revision });
    },
    now: () => 1_800_000_000_000,
  };
  return { reporter: sourceMetadataReporter('acct', deps), submitted, capabilityCalls: () => capabilityCalls };
}

describe('device-read metadata in the browser', () => {
  it('sends nothing while the server doesn\'t ask (off, or another format)', async () => {
    for (const setting of [false, 'v2'] as const) {
      const h = harness(setting);
      h.reporter.source(ref('m1'), dpoPage);
      await h.reporter.settled();
      expect(h.submitted).toEqual([]);
    }
  });

  it('reads the page it already downloaded and sends the record once per import and version', async () => {
    const h = harness(true);
    h.reporter.source(ref('m1'), dpoPage);
    await h.reporter.settled();
    h.reporter.source(ref('m1'), dpoPage);
    await h.reporter.settled();
    expect(h.submitted).toHaveLength(1);
    expect(h.submitted[0].importID).toBe('m1'); expect(h.submitted[0].revision).toBe(3);
    expect(h.submitted[0].metadata.origin).toBe('arxiv_html');
    expect(h.submitted[0].metadata.title).toBe('Direct Preference Optimization: Your Language Model is Secretly a Reward Model');
    expect(h.capabilityCalls()).toBe(1);
  });

  it('a page for another version sends nothing; a failed send is tried again the next time', async () => {
    const h = harness(true, 1);
    h.reporter.source(ref('m1', '2305.18290', 2), dpoPage);
    await h.reporter.settled();
    expect(h.submitted).toEqual([]);
    h.reporter.source(ref('m1'), dpoPage);
    await h.reporter.settled();
    expect(h.submitted).toEqual([]);
    h.reporter.source(ref('m1'), dpoPage);
    await h.reporter.settled();
    expect(h.submitted.map(s => [s.importID, s.revision])).toEqual([['m1', 3]]);
  });
});
