// The device's source-metadata reader over the real-paper corpus on this machine (`npm run test:slow:fetch`). Moved out
// of the fast backend suite (review D5, 2026-10-21), where it skipped silently without the local downloads; the corpus
// tier runs it and fails when the corpus is missing. Every paper gives a record except the two whose author block is a
// logo or a report title, which give none (the device then sends nothing).
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { extractSourceMetadata } from '../../supabase/functions/_shared/reader/arxiv/source-metadata.ts';

const now = new Date('2026-10-15T12:00:00Z');
const corpus = new URL('../../.artifacts/reader-corpus/', import.meta.url);

test('the pinned corpus gives source metadata as the device reads it', () => {
  assert.ok(existsSync(corpus), 'the reader corpus is missing: run `npm run test:slow:fetch` on this device first');
  const none = new Set(['2610.13527v1', '2610.16352v1']);
  let papers = 0;
  for (const name of readdirSync(corpus).sort()) {
    const path = new URL(`${name}/source.html`, corpus);
    if (!existsSync(path)) continue;
    papers++;
    const [, id, revision] = /^(.*)v(\d+)$/.exec(name)!;
    const result = extractSourceMetadata(readFileSync(path, 'utf8'), id, Number(revision), now);
    if (none.has(name)) { assert.equal(result, null, name); continue; }
    assert.ok(result, name);
    const m = result!.metadata;
    assert.ok(m.title.length > 10 && m.authors.length >= 1 && m.abstract && m.license_uri && m.categories.length === 1 && m.version_date, name);
    for (const author of m.authors) assert.doesNotMatch(author, /universit|institut|corresponding|equal contribution|@/i, `${name}: ${author}`);
  }
  assert.ok(papers > 0, 'the reader corpus has no cached HTML sources');
});
