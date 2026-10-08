// The published chat profile table (GET functions/v1/chat) is checked into the Swift fixtures so the app's and the
// browser's decoders are tested against exactly what the server sends. Regenerate deliberately with
// `node tests/backend/chat-profiles-fixture.test.ts --write-fixture` after a reviewed profile change.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { publishedProfiles } from '../../supabase/functions/_shared/chat-profiles.ts';

const fixture = new URL('../../apps/apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/chat-profiles-v1.json', import.meta.url);
const encoded = JSON.stringify(publishedProfiles(), null, 2) + '\n';
if (process.argv.includes('--write-fixture')) writeFileSync(fixture, encoded);

test('the checked-in chat profile fixture is exactly the published table', () => {
  assert.equal(readFileSync(fixture, 'utf8'), encoded, 'chat-profiles-v1.json differs from publishedProfiles(); review and regenerate');
});
