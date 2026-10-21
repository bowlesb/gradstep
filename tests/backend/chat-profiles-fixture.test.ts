// The published chat profile table (GET functions/v1/chat), checked in as the server's own fixtures so the app's and the
// browser's decoder fixtures can be refreshed from exactly what the server sends. Regenerate deliberately with
// `node tests/backend/chat-profiles-fixture.test.ts --write-fixture` after a reviewed profile change. They are the table as
// staging serves it with DeepSeek on (CHAT_DEEPSEEK=on), without and with Gemini Flash; every model is served through
// OpenRouter (owner, 2026-10-18 and 2026-10-21). tests/fixtures/chat-profiles-v1-build57.json keeps the one builds 57/58
// shipped with (tests/backend/chat-profiles.test.ts decodes both as those builds do).
//
// The Swift copies (apps/apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/chat-profiles-v1.json and
// chat-profiles-gemini.json) and the browser's (apps/web/tests/fixtures/chat-profiles-v1.json) are owned by those apps;
// on 2026-10-21 they still held the table from before every model went through OpenRouter, and are refreshed from these.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { publishedProfiles } from '../../supabase/functions/_shared/chat-profiles.ts';

const fixture = new URL('../fixtures/chat-profiles-v1.json', import.meta.url);
const encoded = JSON.stringify(publishedProfiles({ deepseek: true }), null, 2) + '\n';
if (process.argv.includes('--write-fixture')) writeFileSync(fixture, encoded);

test('the checked-in chat profile fixture is exactly the published table', () => {
  assert.equal(readFileSync(fixture, 'utf8'), encoded, 'chat-profiles-v1.json differs from publishedProfiles(); review and regenerate');
});

const geminiFixture = new URL('../fixtures/chat-profiles-gemini.json', import.meta.url);
const geminiEncoded = JSON.stringify(publishedProfiles({ deepseek: true, gemini: true }), null, 2) + '\n';
if (process.argv.includes('--write-fixture')) writeFileSync(geminiFixture, geminiEncoded);
test('the Flash rollout fixture is the exact enabled table', () => {
  assert.equal(readFileSync(geminiFixture, 'utf8'), geminiEncoded);
});

test('every model in the published table is served through OpenRouter', () => {
  for (const table of [JSON.parse(encoded), JSON.parse(geminiEncoded)]) {
    for (const model of table.models) assert.equal(model.provider, 'openrouter', model.id);
    assert.ok(!/"provider": "(?:anthropic|deepseek)"/.test(JSON.stringify(table, null, 1)));
  }
});
