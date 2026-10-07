import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Server } from 'node:http';
import { handle, sameSecret } from '../../services/pipeline-worker/server.ts';

const secret = 's'.repeat(40);
async function serve(): Promise<{ server: Server; url: string }> {
  const server = createServer((request, response) => { void handle(request, response, secret); });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address() as { port: number };
  return { server, url: `http://127.0.0.1:${address.port}` };
}

test('the Cloud Run worker answers health checks and refuses calls without the pipeline secret', async () => {
  const { server, url } = await serve();
  try {
    assert.equal((await fetch(`${url}/health`)).status, 200);
    assert.equal((await fetch(url, { method: 'GET' })).status, 405);
    assert.equal((await fetch(url, { method: 'POST' })).status, 401);
    assert.equal((await fetch(url, { method: 'POST', headers: { 'x-pipeline-secret': 'x'.repeat(40) } })).status, 401);
  } finally { server.close(); }
  assert.ok(sameSecret(secret, secret));
  assert.ok(!sameSecret(secret, secret.slice(1)));
});
