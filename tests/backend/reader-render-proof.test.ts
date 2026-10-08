import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { readRenderArtifact, loopbackRequestAllowed } from '../../scripts/reader-render-proof.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const content = Buffer.from('public fixture');
function fixture() {
  const manifest = Buffer.from(JSON.stringify({ members: [{ path: 'reader.html', bytes: content.length, sha256: sha(content) }] }));
  return { format: 'gradstep-reader-render-proof-v1', source_id: '2305.18290', manifest_sha256: sha(manifest),
    manifest: manifest.toString('base64'), members: [{ path: 'reader.html', base64: content.toString('base64') }] };
}
const read = value => readRenderArtifact(Buffer.from(JSON.stringify(value)));

test('local artifact accepts only public bounded, canonically encoded bytes with exact digests', () => {
  assert.deepEqual(read(fixture()), fixture());
  for (const mutate of [value => { value.token = 'never accepted'; }, value => { value.source_id = 'private'; },
    value => { value.members[0].url = 'https://example.invalid/signed'; }, value => { value.members.push(value.members[0]); },
    value => { value.members[0].path = '../reader.html'; }, value => { value.members[0].base64 += '\n'; },
    value => { value.members[0].base64 = Buffer.from('modified').toString('base64'); }, value => { value.manifest_sha256 = '0'.repeat(64); }]) {
    const value = fixture(); mutate(value); assert.throws(() => read(value));
  }
  assert.throws(() => readRenderArtifact(Buffer.alloc(1_600_001)));
});

test('proof browser permits only its exact ephemeral loopback origin and two static routes', () => {
  const origin = 'http://127.0.0.1:43210';
  for (const path of ['/', '/proof.js']) assert.equal(loopbackRequestAllowed(origin + path, origin), true);
  for (const value of ['https://example.invalid/', 'http://localhost:43210/', 'http://127.0.0.1:43211/',
    origin + '/artifact.json', origin + '/proof.js?token=x', origin + '/#x', 'http://user:pass@127.0.0.1:43210/', 'data:text/html,x']) {
    assert.equal(loopbackRequestAllowed(value, origin), false);
  }
  assert.equal(loopbackRequestAllowed('https://example.invalid/', 'https://example.invalid'), false);
});
