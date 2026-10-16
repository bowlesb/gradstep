import test from 'node:test';
import assert from 'node:assert/strict';
import { EgressBlocked, egressMode, guardedFetch, isArxivHost, requestHost, type EgressMode } from '../../supabase/functions/_shared/egress.ts';

// "No server request to arXiv" (docs/architecture/ARXIV_DEVICE_ONLY.md §6, step 1): the fetch guard on every server.

test('every spelling of an arXiv host is recognized, and nothing else is', () => {
  for (const url of ['https://arxiv.org/abs/1', 'https://export.arxiv.org/api/query', 'http://oaipmh.arxiv.org/oai', 'https://RSS.ARXIV.ORG/rss/cs.LG',
    'https://arxiv.org./html/2305.18290v3', 'https://www.arxiv.org..', 'https://ａｒｘｉｖ.org/abs/1', 'https://static.arxiv.org/x.css']) {
    const host = requestHost(url);
    assert.ok(host !== null && isArxivHost(host), url);
  }
  for (const url of ['https://api.datacite.org/dois/10.48550/arXiv.2305.18290', 'https://notarxiv.org/', 'https://arxiv.org.evil.example/',
    'https://xn--arxiv-ufa.org/', 'https://alphaxiv.org/abs/1', 'https://api.openalex.org/works']) {
    const host = requestHost(url);
    assert.ok(host === null || !isArxivHost(host), url);
  }
  assert.equal(requestHost('mailto:hello@arxiv.org'), null, 'only http(s) requests count');
  assert.equal(requestHost('not a url'), null);
  assert.equal(requestHost(new URL('https://arxiv.org/x')), 'arxiv.org');
  assert.equal(requestHost(new Request('https://export.arxiv.org/api/query')), 'export.arxiv.org');
});

function harness(mode: EgressMode, routes: Record<string, () => Response>) {
  const requested: string[] = [], logs: string[] = [];
  const inner = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    requested.push(`${init?.redirect ?? 'follow'} ${init?.method ?? 'GET'} ${url}`);
    const route = routes[url];
    if (!route) return new Response('ok', { status: 200 });
    return route();
  }) as typeof fetch;
  return { requested, logs, fetch: guardedFetch(inner, 'test-caller', { mode: () => mode, log: line => logs.push(line) }) };
}
const redirect = (to: string, status = 302) => () => new Response(null, { status, headers: { location: to } });

test('report mode lets the request through and logs the host, never the path', async () => {
  const h = harness('report', {});
  const response = await h.fetch('https://export.arxiv.org/api/query?search_query=secret%20words');
  assert.equal(response.status, 200);
  assert.equal(h.requested.length, 1);
  assert.deepEqual(JSON.parse(h.logs[0]), { event: 'arxiv_egress', mode: 'report', host: 'export.arxiv.org', caller: 'test-caller', blocked: false });
  assert.doesNotMatch(h.logs[0], /secret/);
});

test('block mode refuses arXiv before any request, including uppercase, a trailing dot and plain http', async () => {
  for (const url of ['https://export.arxiv.org/api/query', 'https://ARXIV.ORG/abs/1', 'https://arxiv.org./html/1v1', 'http://rss.arxiv.org/rss/cs.LG']) {
    const h = harness('block', {});
    await assert.rejects(h.fetch(url), (error: unknown) => error instanceof EgressBlocked && error.code === 'arxiv_egress_blocked');
    assert.equal(h.requested.length, 0, url);
    assert.equal(JSON.parse(h.logs[0]).blocked, true);
  }
});

test('block mode checks every redirect hop and refuses the hop to arXiv without requesting it', async () => {
  const h = harness('block', {
    'https://doi.org/10.48550/arXiv.2305.18290': redirect('https://publisher.example/landing'),
    'https://publisher.example/landing': redirect('http://export.arxiv.org/abs/2305.18290', 301),
  });
  await assert.rejects(h.fetch('https://doi.org/10.48550/arXiv.2305.18290'), EgressBlocked);
  assert.deepEqual(h.requested, ['manual GET https://doi.org/10.48550/arXiv.2305.18290', 'manual GET https://publisher.example/landing']);
  assert.equal(JSON.parse(h.logs[0]).host, 'export.arxiv.org');
  // A redirect chain that never reaches arXiv is followed to its end; a 303 becomes a GET.
  const ok = harness('block', { 'https://a.example/': redirect('https://b.example/', 303) });
  const response = await ok.fetch('https://a.example/', { method: 'POST', body: 'x' });
  assert.equal(response.status, 200);
  assert.deepEqual(ok.requested, ['manual POST https://a.example/', 'manual GET https://b.example/']);
  // Code that handles redirects itself (redirect: 'manual') sees each hop through the guard anyway.
  const manual = harness('block', { 'https://a.example/': redirect('https://arxiv.org/abs/1') });
  const hop = await manual.fetch('https://a.example/', { redirect: 'manual' });
  assert.equal(hop.status, 302);
  await assert.rejects(manual.fetch(new URL(hop.headers.get('location')!, 'https://a.example/'), { redirect: 'manual' }), EgressBlocked);
});

test('report mode notices a platform-followed redirect that ended on arXiv', async () => {
  const logs: string[] = [];
  const inner = (async () => { const r = new Response('x', { status: 200 }); Object.defineProperty(r, 'redirected', { value: true }); Object.defineProperty(r, 'url', { value: 'https://arxiv.org/abs/1' }); return r; }) as typeof fetch;
  await guardedFetch(inner, 'c', { mode: () => 'report', log: line => logs.push(line) })('https://doi.org/x');
  assert.equal(JSON.parse(logs[0]).host, 'arxiv.org');
});

test('block is the default since the cutover: only an explicit EGRESS_ARXIV=report lets a request through', async () => {
  const saved = process.env.EGRESS_ARXIV;
  try {
    for (const [value, mode] of [[undefined, 'block'], ['block', 'block'], ['', 'block'], ['off', 'block'], ['report', 'report']] as const) {
      if (value === undefined) delete process.env.EGRESS_ARXIV; else process.env.EGRESS_ARXIV = value;
      assert.equal(egressMode(), mode, String(value));
    }
    delete process.env.EGRESS_ARXIV;
    let requested = 0;
    const guarded = guardedFetch(async () => { requested++; return new Response('x'); }, 'default', { log: () => {} });
    await assert.rejects(guarded('https://export.arxiv.org/api/query?id_list=1'), EgressBlocked);
    assert.equal(requested, 0);
  } finally { if (saved === undefined) delete process.env.EGRESS_ARXIV; else process.env.EGRESS_ARXIV = saved; }
});
