import test from 'node:test';
import assert from 'node:assert/strict';
import { POOL_CATEGORY } from '../../supabase/functions/_shared/feed-pool.ts';

test('a Feed chip names any arXiv category form, including one-letter archives (q-bio, q-fin) and physics subclasses', () => {
  for (const ok of ['cs.LG', 'stat.ML', 'q-bio.NC', 'q-fin.ST', 'astro-ph.GA', 'cond-mat.stat-mech', 'physics.comp-ph', 'eess.IV', 'math.OC', 'cs'])
    assert.ok(POOL_CATEGORY.test(ok), ok);
  for (const bad of ['', 'CS.LG', 'cs.lg.extra', 'cs..LG', 'cs.L', 'q', '../etc', 'cs.LG;drop']) assert.ok(!POOL_CATEGORY.test(bad), bad);
});
