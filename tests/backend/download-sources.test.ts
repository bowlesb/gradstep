// Web download patterns found on real hosts (survey 2026-10-07; docs/architecture/PIPELINE_RELIABILITY.md
// "Self-healing downloads"): landing pages as repositories really write them, refusals told apart for
// readers, bodies sniffed rather than trusted, PubMed Central through NLM's open data, location order.
import test from 'node:test';
import assert from 'node:assert/strict';
import { PDFDocument } from 'pdf-lib';
import { downloadLocations, fetchFirstWebPDF, fetchWebPDF, landingPagePDF, openDataPDF, openPDFLocations, refusal, WebSourceError,
  type ResolveHost } from '../../supabase/functions/_shared/web-source.ts';
import { runPipeline, type PipelineDeps } from '../../supabase/functions/_shared/pipeline.ts';

const permanent = (code: string) => (e: unknown) => e instanceof WebSourceError && e.permanent && e.code === code;
const transient = (code: string) => (e: unknown) => e instanceof WebSourceError && !e.permanent && e.code === code;
const resolve: ResolveHost = async () => ['93.184.215.14'];
const page = (head: string, body = '') => `<!doctype html><html><head><title>Record</title>${head}</head><body>${body}</body></html>`;
const href = (html: string, base: string) => landingPagePDF(html, new URL(base))?.href ?? null;

test('landing pages as real repositories write them', () => {
  // PMLR, JMLR and CVF declare http links: fetched over https.
  assert.equal(href(page('<meta name="citation_pdf_url" content="http://proceedings.mlr.press/v37/ioffe15.pdf">'), 'https://proceedings.mlr.press/v37/ioffe15.html'),
    'https://proceedings.mlr.press/v37/ioffe15.pdf');
  assert.equal(href(page('<meta name="citation_pdf_url" content="http://www.cv-foundation.org/openaccess/content_cvpr_2016/papers/He_Deep_Residual_Learning_CVPR_2016_paper.pdf">'),
    'https://openaccess.thecvf.com/content_cvpr_2016/html/He_Deep_Residual_Learning_CVPR_2016_paper.html'),
  'https://www.cv-foundation.org/openaccess/content_cvpr_2016/papers/He_Deep_Residual_Learning_CVPR_2016_paper.pdf');
  // ACL Anthology leaves attribute values unquoted.
  assert.equal(href('<meta charset=utf-8><meta content="https://aclanthology.org/N19-1423.pdf" name=citation_pdf_url><meta content="4171" name=citation_firstpage>',
    'https://aclanthology.org/N19-1423/'), 'https://aclanthology.org/N19-1423.pdf');
  assert.equal(href('<meta name=citation_pdf_url content=https://example.org/a.pdf/>', 'https://example.org/x'), 'https://example.org/a.pdf');
  // DSpace 7 names its own host as localhost:4000; that means the page's host.
  assert.equal(href(page('<meta name="citation_pdf_url" property="citation_pdf_url" content="http://localhost:4000/bitstreams/e2715ecb-c73b-4810-98a4-1c6848367a01/download">'),
    'https://aura.abdn.ac.uk/items/669c2d31'), 'https://aura.abdn.ac.uk/bitstreams/e2715ecb-c73b-4810-98a4-1c6848367a01/download');
  // bepress (Digital Commons), entities decoded; fragments dropped.
  assert.equal(href(page('<meta name="bepress_citation_pdf_url" content="https://repository.upenn.edu/cgi/viewcontent.cgi?article=1162&amp;context=cis_papers">'),
    'https://repository.upenn.edu/cis_papers/159'), 'https://repository.upenn.edu/cgi/viewcontent.cgi?article=1162&context=cis_papers');
  assert.equal(href(page('<meta name="citation_pdf_url" content="/files/a.pdf#page=2">'), 'https://repository.example.org/r/1'), 'https://repository.example.org/files/a.pdf');
  // IEEE's stamp page embeds the PDF; a prompt meta refresh leads to it; the declared tag wins.
  assert.equal(href(page('', '<iframe src="https://ieeexplore.ieee.org/ielx7/6287639/6336544/06515173.pdf?tp=&arnumber=6515173&isnumber=6336544&ref=" frameborder=0>'),
    'https://ieeexplore.ieee.org/stamp/stamp.jsp?tp=&arnumber=6515173'), 'https://ieeexplore.ieee.org/ielx7/6287639/6336544/06515173.pdf?tp=&arnumber=6515173&isnumber=6336544&ref=');
  assert.equal(href(page('<meta http-equiv="refresh" content="0; url=/files/paper.pdf">'), 'https://repository.example.org/r/1'), 'https://repository.example.org/files/paper.pdf');
  assert.equal(href(page('<meta http-equiv="refresh" content="360">'), 'https://repository.example.org/r/1'), null, "Cloudflare's 360 s refresh is no link");
  assert.equal(href(page('<meta http-equiv="refresh" content="60; url=/files/paper.pdf">'), 'https://repository.example.org/r/1'), null, 'a slow refresh is not followed');
  assert.equal(href(page('<meta name="citation_pdf_url" content="https://repository.example.org/declared.pdf">', '<iframe src="/viewer.pdf">'),
    'https://repository.example.org/r/1'), 'https://repository.example.org/declared.pdf');
  // Never a private or local target that cannot be rebased.
  assert.equal(href(page('<meta name="citation_pdf_url" content="https://10.0.0.5/a.pdf">'), 'https://repository.example.org/r/1'), null);
  assert.equal(href(page('<meta name="data-citation_pdf_url" content="https://repository.example.org/a.pdf">'), 'https://repository.example.org/r/1'), null);
});

test('what a refusal means for the reader: sign-in or paywall, bot check, or no PDF', () => {
  const at = new URL('https://publisher.example.com/doi/pdf/10.1/x');
  assert.equal(refusal('', at, 401), 'pdf_restricted');
  assert.equal(refusal('', at, 402), 'pdf_restricted');
  assert.equal(refusal('<!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title><meta http-equiv="refresh" content="360"></head></html>', at, 403), 'source_blocked');
  // OpenReview's Turnstile page offers a sign-in, but it is a bot check.
  assert.equal(refusal('<title>Verifying your browser | OpenReview</title><div class="cf-turnstile"></div><p class="login-hint">Have an OpenReview account? <a href="/login?redirect=%2Fpdf">Sign in</a> to skip this check.</p>',
    new URL('https://openreview.net/challenge?redirect=%2Fpdf'), 200), 'source_blocked');
  assert.equal(refusal('<HTML><HEAD><TITLE>ERROR: The request could not be satisfied</TITLE></HEAD></HTML>', at, 403), 'source_blocked');
  assert.equal(refusal('<HTML><HEAD>\n<TITLE>Access Denied</TITLE>\n</HEAD><BODY>You don\'t have permission. Reference #18</BODY></HTML>', at, 403), 'source_blocked');
  assert.equal(refusal('<html><head><title>Preparing to download ...</title></head><body><script>/* cloudpmc-viewer-pow */</script></body></html>', at, 200), 'source_blocked');
  assert.equal(refusal('<title>Human Verification</title>', at, 405), 'source_blocked');
  assert.equal(refusal('<title>Sign in</title><form><input name=user><input type="password" name=pw></form>', at, 200), 'pdf_restricted');
  assert.equal(refusal('<title>Welcome</title>', new URL('https://idp.publisher.example.com/authorize?client_id=x'), 200), 'pdf_restricted');
  assert.equal(refusal('<title>Article</title><p>Purchase this article for $39.95 or access through your institution.</p>', at, 200), 'pdf_restricted');
  // Only visible text counts: scripts mention purchases on open pages too; a newsletter is no paywall.
  assert.equal(refusal('<title>Record</title><script>var labels={"x":"Buy this article"}</script><p>Subscribe to our newsletter. <a href="/login">Log in</a></p>', at, 200), 'not_pdf');
  assert.equal(refusal('no', at, 403), 'source_blocked');
  assert.equal(refusal('', at, 400), 'download_failed');
});

test('downloads are sniffed, refusals classified, PubMed Central fetched from open data', async () => {
  const doc = await PDFDocument.create(); doc.addPage(); const body = await doc.save();
  const seen: string[] = [];
  const fetcher = (async (url: string) => {
    seen.push(url);
    const { hostname, pathname } = new URL(url);
    const html = (text: string, status = 200, headers: Record<string, string> = {}) => new Response(text, { status, headers: { 'content-type': 'text/html', ...headers } });
    if (hostname === 'pmc-oa-opendata.s3.amazonaws.com') return pathname === '/PMC4103590.1/PMC4103590.1.pdf' ? new Response(body, { headers: { 'content-type': 'binary/octet-stream' } }) : new Response('NoSuchKey', { status: 404 });
    if (pathname === '/pdf-as-html') return new Response(body, { headers: { 'content-type': 'text/html; charset=utf-8' } });
    if (pathname === '/page-as-pdf') return new Response(page('<meta name="citation_pdf_url" content="/pdf-as-html">'), { headers: { 'content-type': 'application/pdf' } });
    if (pathname === '/padded-page') return new Response(`﻿\n\n   \n${page('<meta name="citation_pdf_url" content="/pdf-as-html">')}`, { headers: { 'content-type': 'application/octet-stream' } });
    if (pathname === '/big-page') return html(page('<meta name="citation_pdf_url" content="/pdf-as-html">', 'x'.repeat(2_000_000)));
    if (pathname === '/cloudflare') return html('<title>Just a moment...</title>', 403, { 'cf-mitigated': 'challenge' });
    if (pathname === '/aws-waf') return new Response(null, { status: 202, headers: { 'x-amzn-waf-action': 'challenge' } });
    if (pathname === '/login') return new Response('', { status: 401 });
    if (pathname === '/dspace-captcha') return html('<!DOCTYPE html><html lang="en"><head><title>Human Verification</title></head></html>', 405);
    if (pathname === '/zip') return new Response(new Uint8Array([0x50, 0x4b, 0x03, 0x04, 1, 2, 3, 4, 5, 6]), { headers: { 'content-type': 'application/pdf' } });
    if (pathname === '/gone') return new Response('', { status: 404 });
    if (pathname === '/tls') throw new TypeError('fetch failed', { cause: Object.assign(new Error('unable to verify the first certificate'), { code: 'UNABLE_TO_VERIFY_LEAF_SIGNATURE' }) });
    if (pathname === '/reset') throw new TypeError('fetch failed', { cause: Object.assign(new Error('socket hang up'), { code: 'ECONNRESET' }) });
    if (pathname === '/paywall') return html(page('', '<h1>Article</h1><p>Purchase this article or log in via your institution.</p>'));
    // A sign-in round trip (Springer's cookie check, HighWire's implicit login) carries a long token.
    if (pathname === '/round-trip') return new Response(null, { status: 303, headers: { location: `https://idp.repository.example.org/authorize?token=${'t'.repeat(1500)}` } });
    if (hostname === 'idp.repository.example.org') return new Response(null, { status: 302, headers: { location: `${base}/pdf-as-html?error=cookies_not_supported` } });
    throw new Error(`unexpected ${url}`);
  }) as unknown as typeof fetch;
  const base = 'https://repository.example.org';
  const ok = async (path: string) => assert.deepEqual(await fetchWebPDF(fetcher, `${base}${path}`, 1024 * 1024, resolve), body, path);
  await ok('/pdf-as-html');
  await ok('/page-as-pdf');
  await ok('/padded-page');
  await ok('/big-page');
  await ok('/round-trip');
  await assert.rejects(fetchWebPDF(fetcher, `${base}/pdf-as-html?${'q'.repeat(1500)}`, 1024 * 1024, resolve), permanent('download_failed'), 'stored locations stay short');
  await assert.rejects(fetchWebPDF(fetcher, `${base}/cloudflare`, 1024 * 1024, resolve), permanent('source_blocked'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/aws-waf`, 1024 * 1024, resolve), permanent('source_blocked'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/login`, 1024 * 1024, resolve), permanent('pdf_restricted'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/dspace-captcha`, 1024 * 1024, resolve), permanent('source_blocked'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/zip`, 1024 * 1024, resolve), permanent('not_pdf'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/gone`, 1024 * 1024, resolve), permanent('download_failed'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/paywall`, 1024 * 1024, resolve), permanent('pdf_restricted'));
  // An unverifiable certificate will not fix itself in a minute; a reset might.
  await assert.rejects(fetchWebPDF(fetcher, `${base}/tls`, 1024 * 1024, resolve), permanent('download_failed'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/reset`, 1024 * 1024, resolve), transient('download_failed'));
  // PubMed Central article pages and PDF links (browser-only) are fetched from NLM's open data.
  seen.length = 0;
  assert.deepEqual(await fetchWebPDF(fetcher, 'https://pmc.ncbi.nlm.nih.gov/articles/PMC4103590/pdf/btu170.pdf', 1024 * 1024, resolve), body);
  assert.deepEqual(seen, ['https://pmc-oa-opendata.s3.amazonaws.com/PMC4103590.1/PMC4103590.1.pdf']);
  for (const url of ['https://www.ncbi.nlm.nih.gov/pmc/articles/4103590', 'https://europepmc.org/articles/PMC4103590', 'https://europepmc.org/article/PMC/PMC4103590'])
    assert.equal(openDataPDF(new URL(url))?.href, 'https://pmc-oa-opendata.s3.amazonaws.com/PMC4103590.1/PMC4103590.1.pdf', url);
  assert.equal(openDataPDF(new URL('https://europepmc.org/abstract/MED/24695404')), null, 'a PubMed id is not a PMC id');
  assert.equal(openDataPDF(new URL('https://pubmed.ncbi.nlm.nih.gov/24695404')), null);
  // One location paywalled, one gone: the reader is told about the paywall.
  await assert.rejects(fetchFirstWebPDF(fetcher, [`${base}/gone`, `${base}/paywall`], 1024 * 1024, resolve), permanent('pdf_restricted'));
});

test('download locations: open hosts first, PubMed Central through open data, repository records, challenged hosts last', () => {
  // MrBayes 3.2 (W2148698435): OUP challenges every non-browser request; PMC and eScholarship hold copies.
  const mrbayes = {
    best_oa_location: { pdf_url: 'https://academic.oup.com/sysbio/article-pdf/61/3/539/24563565/sys029.pdf', is_oa: true },
    locations: [
      { pdf_url: 'https://academic.oup.com/sysbio/article-pdf/61/3/539/24563565/sys029.pdf', landing_page_url: 'https://doi.org/10.1093/sysbio/sys029', is_oa: true, source: { type: 'journal' } },
      { pdf_url: null, landing_page_url: 'https://www.ncbi.nlm.nih.gov/pmc/articles/3329765', is_oa: true, source: { type: 'repository' } },
      { pdf_url: null, landing_page_url: 'https://pubmed.ncbi.nlm.nih.gov/22357727', is_oa: false, source: { type: 'repository' } },
      { pdf_url: null, landing_page_url: 'https://escholarship.org/uc/item/5nd8r4p9', is_oa: true, source: { type: 'repository' } },
      { pdf_url: null, landing_page_url: 'http://hdl.handle.net/10453/32372', is_oa: false, source: { type: 'repository' } },
    ],
  };
  assert.deepEqual(downloadLocations(mrbayes), ['https://pmc-oa-opendata.s3.amazonaws.com/PMC3329765.1/PMC3329765.1.pdf',
    'https://escholarship.org/uc/item/5nd8r4p9', 'https://academic.oup.com/sysbio/article-pdf/61/3/539/24563565/sys029.pdf']);
  // Ingest's notion of an open copy is unchanged.
  assert.deepEqual(openPDFLocations(mrbayes), ['https://academic.oup.com/sysbio/article-pdf/61/3/539/24563565/sys029.pdf']);
  // An open host keeps its place; arXiv and closed locations never appear; at most three.
  const open = {
    best_oa_location: { pdf_url: 'https://www.frontiersin.org/articles/10.3389/fnins.2011.00073/pdf', is_oa: true },
    locations: [
      { pdf_url: 'https://arxiv.org/pdf/1101.0001', is_oa: true, source: { type: 'repository' } },
      { pdf_url: 'https://pmc.ncbi.nlm.nih.gov/articles/PMC3130465/pdf/fnins-05-00073.pdf', is_oa: true, source: { type: 'repository' } },
      { pdf_url: null, landing_page_url: 'https://doi.org/10.5281/zenodo.19667963', is_oa: true, source: { type: 'repository' } },
      { pdf_url: null, landing_page_url: 'https://hal.science/hal-00000001', is_oa: true, source: { type: 'repository' } },
      { pdf_url: null, landing_page_url: 'https://www.nature.com/articles/x', is_oa: true, source: { type: 'journal' } },
    ],
  };
  assert.deepEqual(downloadLocations(open), ['https://www.frontiersin.org/articles/10.3389/fnins.2011.00073/pdf',
    'https://pmc-oa-opendata.s3.amazonaws.com/PMC3130465.1/PMC3130465.1.pdf', 'https://doi.org/10.5281/zenodo.19667963']);
  assert.deepEqual(downloadLocations({ locations: [{ pdf_url: 'https://arxiv.org/pdf/1101.0001', is_oa: true }] }), []);
  assert.deepEqual(downloadLocations(null), []);
});

test('the pipeline sweeps automatic retries and credit resumes before it claims, and never stops on those sweeps', async () => {
  const run = async (enabled: boolean, sweep: () => unknown, resume: () => unknown = () => null) => {
    const calls: string[] = [];
    const logs: string[] = [];
    const deps = {
      async rpc(name: string, params: Record<string, unknown>) {
        calls.push(name);
        if (name === 'worker_pipeline_policy') return { enabled, max_pdf_bytes: 1, max_ocr_pages: 1, renderer_version: 'v' };
        if (name === 'worker_pipeline_auto_retry') { assert.deepEqual(params, { p_min_interval_seconds: 20 }); return sweep(); }
        if (name === 'worker_pipeline_resume_credits') { assert.deepEqual(params, { p_min_interval_seconds: 10 }); return resume(); }
        return null;
      },
      log(event: string) { logs.push(event); }, uuid: () => '33333333-3333-4333-8333-333333333333', now: () => 0,
    } as unknown as PipelineDeps;
    await runPipeline(deps, 1e12);
    return { calls, logs };
  };
  const swept = await run(true, () => ({ retried: 2, healed: 1, postponed: 0 }), () => ({ swept: true, resumed: 1, limited: 0 }));
  assert.deepEqual(swept.calls, ['worker_pipeline_policy', 'worker_expire_stale_chat_operations', 'worker_asset_maintenance', 'worker_pipeline_auto_retry',
    'worker_pipeline_resume_credits', 'worker_pipeline_claim']);
  assert.ok(swept.logs.includes('auto_retry') && swept.logs.includes('credit_resume'));
  const broken = await run(true, () => { throw new Error('function missing (027 not applied)'); }, () => { throw new Error('function missing (040 not applied)'); });
  assert.ok(broken.calls.includes('worker_pipeline_claim') && broken.logs.includes('auto_retry_failed') && broken.logs.includes('credit_resume_failed'));
  const off = await run(false, () => null);
  assert.ok(!off.calls.includes('worker_pipeline_auto_retry') && !off.calls.includes('worker_pipeline_resume_credits'), 'nothing is retried or resumed while the pipeline is off');
});
