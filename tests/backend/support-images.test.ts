import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectImage } from '../../supabase/functions/_shared/images.ts';
import { readBounded, sha256 } from '../../supabase/functions/_shared/http.ts';

// One RGB pixel, encoded with Python's zlib/struct; CRCs independently verified.
const pixel = Uint8Array.from(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNITvsIAALqAbsZhJbTAAAAAElFTkSuQmCC', 'base64'));

test('image ingress rejects HTML, SVG, corrupt PNG chunks and appended payloads', () => {
  for (const value of ['<svg xmlns="http://www.w3.org/2000/svg"/>', '<html><script>alert(1)</script></html>']) assert.throws(() => inspectImage(new TextEncoder().encode(value)), /invalid_image/);
  assert.deepEqual(inspectImage(pixel), { mediaType: 'image/png', width: 1, height: 1 });
  const changed = pixel.slice(); changed[45] ^= 1;
  assert.throws(() => inspectImage(changed), /invalid_image/);
  const appended = Uint8Array.from([...pixel, 1, 2, 3]);
  assert.throws(() => inspectImage(appended), /invalid_image/);
});

test('declared or streamed attachment bodies cannot exceed the bound', async () => {
  await assert.rejects(readBounded(new Request('https://example.invalid', { method: 'POST', headers: { 'content-length': '50' }, body: 'abc' }), 4), /attachment_too_large/);
  const streamed = new Request('https://example.invalid', { method: 'POST', body: new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(3)); controller.enqueue(new Uint8Array(3)); controller.close(); } }), duplex: 'half' } as RequestInit);
  await assert.rejects(readBounded(streamed, 5), /attachment_too_large/);
  const data = await readBounded(new Request('https://example.invalid', { method: 'POST', body: 'hello' }), 5);
  assert.equal(await sha256(data), '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');
});
