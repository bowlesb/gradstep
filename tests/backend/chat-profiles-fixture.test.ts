// The published chat profile table (GET functions/v1/chat) is checked into the Swift fixtures so the app's and the
// browser's decoders are tested against exactly what the server sends. Regenerate deliberately with
// `node tests/backend/chat-profiles-fixture.test.ts --write-fixture` after a reviewed profile change. It is the table
// as staging serves it with DeepSeek on (CHAT_DEEPSEEK=on); tests/fixtures/chat-profiles-v1-build57.json keeps the one
// builds 57/58 shipped with (tests/backend/chat-profiles.test.ts decodes both as those builds do).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { publishedProfiles } from '../../supabase/functions/_shared/chat-profiles.ts';

const fixture = new URL('../../apps/apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/chat-profiles-v1.json', import.meta.url);
const encoded = JSON.stringify(publishedProfiles({ deepseek: true }), null, 2) + '\n';
if (process.argv.includes('--write-fixture')) writeFileSync(fixture, encoded);

test('the checked-in chat profile fixture is exactly the published table', () => {
  assert.equal(readFileSync(fixture, 'utf8'), encoded, 'chat-profiles-v1.json differs from publishedProfiles(); review and regenerate');
});

const geminiFixture = new URL('../../apps/apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/chat-profiles-gemini.json', import.meta.url);
const geminiEncoded = JSON.stringify(publishedProfiles({ deepseek: true, gemini: true }), null, 2) + '\n';
if (process.argv.includes('--write-fixture')) writeFileSync(geminiFixture, geminiEncoded);
test('the Flash rollout fixture is the exact enabled table', () => {
  assert.equal(readFileSync(geminiFixture, 'utf8'), geminiEncoded);
});
