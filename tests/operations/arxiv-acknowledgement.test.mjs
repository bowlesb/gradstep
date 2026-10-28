// arXiv's required acknowledgement for products that use its API or data (docs/architecture/ARXIV_DEVICE_ONLY.md §7)
// is on every product surface, word for word; and no server identifies itself under the old name or a dead address.
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('../../', import.meta.url).pathname;
const read = path => readFileSync(join(root, path), 'utf8');
const STATEMENT = 'Thank you to arXiv for use of its open access interoperability. This product was not reviewed or approved by, nor does it necessarily express or reflect the policies or opinions of, arXiv.';

test('the acknowledgement is on the apps, the browser and the site', () => {
  assert.ok(read('apps/apple/ScienceReader/Views/SettingsPages.swift').includes(`static let statement = "${STATEMENT}"`), 'native constant');
  assert.match(read('apps/apple/ScienceReader/Views/SettingsPages.swift'), /Text\(ArxivAcknowledgement\.statement\)/, 'How Gradstep works (native)');
  assert.match(read('apps/apple/ScienceReader/Views/RootView.swift'), /Text\(ArxivAcknowledgement\.statement\)/, 'Acknowledgements (native)');
  const web = read('apps/web/src/ui/HowGradstepWorks.tsx');
  assert.ok(web.includes(`ARXIV_ACKNOWLEDGEMENT = '${STATEMENT}'`) && web.includes('{ARXIV_ACKNOWLEDGEMENT}'), 'How Gradstep works (browser)');
  for (const page of ['web/site/index.html', 'web/site/privacy/index.html']) assert.ok(read(page).includes(STATEMENT), page);
});

test('servers identify themselves as Gradstep with a reachable contact', () => {
  const files = [];
  const walk = dir => { for (const name of readdirSync(join(root, dir))) { const path = join(dir, name);
    if (statSync(join(root, path)).isDirectory()) { if (name !== 'node_modules') walk(path); } else if (/\.(ts|js|mjs|py)$/.test(name)) files.push(path); } };
  for (const dir of ['supabase/functions', 'workers', 'services']) { try { walk(dir); } catch { /* absent */ } }
  const stale = files.filter(path => /ScienceReader\/0\.|sciencereader\.invalid/.test(read(path)));
  assert.deepEqual(stale, []);
});
