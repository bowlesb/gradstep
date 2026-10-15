// The static half of "no server request to arXiv" (docs/architecture/ARXIV_DEVICE_ONLY.md §6.5): the scan finds
// requests, not explained mentions, and report mode's ratchet fails only on a new call site.
import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { beyondBaseline, counts, scan, scanText } from '../../scripts/check-arxiv-egress.mjs';

test('a request is found; links, parsing, namespaces, prompts, filters, device code and comments say why and pass', () => {
  const ts = [
    "const a = await fetch('https://export.arxiv.org/api/query?id_list=1');",
    "const b = `https://RSS.ARXIV.ORG/rss/${c}`;",
    "const link = `https://arxiv.org/abs/${id}`; // egress-ok: link",
    "const hosts = new Set(['arxiv.org']); // egress-ok: parse",
    "const NS = 'http://arxiv.org/schemas/atom'; // egress-ok: namespace",
    "// A comment that mentions https://export.arxiv.org/api is not a request.",
    " * nor is a doc comment about oaipmh.arxiv.org",
    "const x = 'https://notarxiv.org/'; const y = 'https://myarxiv.org.example/';",
    "const z = 'https://arxiv.org/x'; // egress-ok: because",
  ].join('\n');
  const found = scanText('supabase/functions/_shared/x.ts', ts);
  assert.deepEqual(found.map(f => [f.line, f.host]), [[1, 'export.arxiv.org'], [2, 'rss.arxiv.org'], [9, 'arxiv.org']], 'an unknown reason is no reason');
});

test('SQL: links built in queries pass; a pg_net request to arXiv is found', () => {
  const sql = [
    "create function f() returns text language sql as $$ select 'https://arxiv.org/abs/'||id||'v'||rev $$;",
    "select net.http_post(url:='https://export.arxiv.org/api/query', body:='{}'::jsonb);",
    "select net.http_post(url:=(select decrypted_secret from vault.decrypted_secrets where name='worker_url'));",
    "-- select net.http_get('https://rss.arxiv.org/rss/cs.LG');",
  ].join('\n');
  assert.deepEqual(scanText('supabase/migrations/1_x.sql', sql).map(f => [f.line, f.host]), [[2, 'export.arxiv.org']]);
});

test('the ratchet: report mode fails only for a site beyond the baseline', () => {
  const findings = [{ path: 'a.ts', line: 1, host: 'arxiv.org' }, { path: 'a.ts', line: 9, host: 'arxiv.org' }, { path: 'b.ts', line: 2, host: 'rss.arxiv.org' }];
  assert.deepEqual(counts(findings), { 'a.ts': 2, 'b.ts': 1 });
  assert.deepEqual(beyondBaseline(findings, { 'a.ts': 2, 'b.ts': 1 }), []);
  assert.deepEqual(beyondBaseline(findings, { 'a.ts': 2 }), [{ path: 'b.ts', count: 1, baseline: 0 }]);
  assert.deepEqual(beyondBaseline(findings.slice(1), { 'a.ts': 2, 'b.ts': 1 }), [], 'retiring a site is always fine');
});

test('the scan covers every server tree, and today\'s repository matches its recorded baseline', () => {
  const root = mkdtempSync(join(tmpdir(), 'egress-scan-'));
  for (const dir of ['supabase/functions/x', 'services/w', 'workers/r', 'supabase/migrations', 'infra', 'scripts', 'apps/web/src', 'supabase/functions/x/node_modules/p'])
    mkdirSync(join(root, dir), { recursive: true });
  const call = "fetch('https://export.arxiv.org/api/query');\n";
  for (const path of ['supabase/functions/x/index.ts', 'services/w/run.ts', 'workers/r/cli.mjs', 'infra/config.json', 'scripts/workflow-checks.mjs', 'scripts/reader-workflow.mjs'])
    writeFileSync(join(root, path), call);
  writeFileSync(join(root, 'apps/web/src/client.ts'), call); // device code is out of scope
  writeFileSync(join(root, 'scripts/other.mjs'), call);        // so are local scripts
  writeFileSync(join(root, 'supabase/functions/x/node_modules/p/index.js'), call);
  assert.deepEqual(scan(root).map(f => f.path), ['infra/config.json', 'scripts/reader-workflow.mjs', 'scripts/workflow-checks.mjs',
    'services/w/run.ts', 'supabase/functions/x/index.ts', 'workers/r/cli.mjs']);
  rmSync(root, { recursive: true, force: true });

  const repository = new URL('../../', import.meta.url).pathname;
  const baseline = JSON.parse(readFileSync(join(repository, 'scripts/arxiv-egress-baseline.json'), 'utf8')).sites;
  assert.deepEqual(beyondBaseline(scan(repository), baseline), [], 'no server call site beyond the recorded baseline');
});
