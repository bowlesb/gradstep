// Topic map build (docs/architecture/INTEREST_INDEX.md §2): spherical k-means, canonical descent, warm-started rebuilds
// that keep IDs, split grown leaves and record successors. Synthetic clustered unit vectors; no corpus needed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DIM } from '../../supabase/functions/_shared/interest/codec.ts';
import { mulberry32, sphericalKMeans } from '../../supabase/functions/_shared/interest/kmeans.ts';
import { assignIDs, buildMap, descend, type BuildResult, type PreviousNode } from '../../supabase/functions/_shared/interest/map-build.ts';

function clustered(n: number, centers: number, seed: number, spread = 0.35, only?: number): Float32Array {
  const random = mulberry32(seed), centerRandom = mulberry32(99);
  const C = Array.from({ length: centers }, () => Float32Array.from({ length: DIM }, () => centerRandom() * 2 - 1));
  const X = new Float32Array(n * DIM);
  for (let r = 0; r < n; r++) {
    const c = C[only ?? Math.floor(random() * centers)];
    let norm = 0;
    for (let i = 0; i < DIM; i++) { const v = c[i] + spread * (random() * 2 - 1); X[r * DIM + i] = v; norm += v * v; }
    norm = Math.sqrt(norm);
    for (let i = 0; i < DIM; i++) X[r * DIM + i] /= norm;
  }
  return X;
}

const small = { topK: 4, midSize: 150, leafSize: 40, keepJaccard: 0.5, keepCos: 0.9, driftMax: 0.05 };
let nextID = 1;
const publish = (result: BuildResult) => assignIDs(result, result.nodes.filter(b => b.id < 0).map(() => nextID++));
const asPrevious = (result: BuildResult, births = new Map<number, Float32Array>()): PreviousNode[] =>
  result.nodes.map(b => ({ id: b.id, level: b.level, parent: b.parent, centroid: b.centroid, birth: births.get(b.id) ?? b.centroid }));

test('k-means is deterministic for a seed and finds well-separated clusters', () => {
  const X = clustered(600, 6, 1, 0.2);
  const idx = Array.from({ length: 600 }, (_, i) => i);
  const a = sphericalKMeans(X, idx, 6, { seed: 3, nInit: 2 }), b = sphericalKMeans(X, idx, 6, { seed: 3, nInit: 2 });
  assert.deepEqual(a.labels, b.labels);
  assert.equal(new Set(a.labels).size, 6);
});

test('cold build: three levels, canonical descent, every row in one leaf', () => {
  const n = 2400, X = clustered(n, 40, 2);
  const result = buildMap(X, n, null, null, small);
  publish(result);
  const levels = [1, 2, 3].map(l => result.nodes.filter(b => b.level === l).length);
  assert.equal(levels[0], 4);
  assert.ok(levels[1] >= 8 && levels[2] >= 40, String(levels));
  assert.equal(result.stats.kind, 'cold');
  const leaves = result.nodes.filter(b => b.level === 3);
  assert.equal(leaves.reduce((s, b) => s + b.members.length, 0), n);
  for (let r = 0; r < n; r += 97) {
    const leaf = descend(X.subarray(r * DIM, r * DIM + DIM), result.nodes);
    assert.equal(leaf.id, result.leafOf[r], 'descent reproduces the stored leaf');
  }
  assert.ok(result.nodes.every(b => b.id > 0 && (b.parent === null || b.parent > 0)));
});

test('warm rebuild on the same data keeps every ID; a grown leaf splits and records successors', () => {
  const n = 2400, X = clustered(n, 40, 2);
  const first = buildMap(X, n, null, null, small);
  publish(first);
  const same = buildMap(X, n, asPrevious(first), first.leafOf, small);
  assert.equal(same.stats.kind, 'warm');
  for (const l of ['1', '2', '3']) assert.equal(same.stats.levels[l].kept_share, 1, `level ${l}`);
  assert.equal(same.nodes.filter(b => b.id < 0).length, 0, 'no new IDs');
  assert.equal(same.retired.length, 0);

  // 300 new papers on top of one cluster: its leaf passes 2x the target and splits; the closer child keeps the ID.
  const extra = clustered(300, 40, 5, 0.35, 7);
  const X2 = new Float32Array((n + 300) * DIM);
  X2.set(X); X2.set(extra, n * DIM);
  const previousLeaf = Int32Array.from({ length: n + 300 }, (_, r) => (r < n ? first.leafOf[r] : -1));
  const grown = buildMap(X2, n + 300, asPrevious(first), previousLeaf, small);
  assert.ok(grown.stats.splits >= 1, 'a leaf split');
  assert.ok(grown.stats.levels['3'].kept_share! >= 0.9, JSON.stringify(grown.stats.levels));
  const newIDs = grown.nodes.filter(b => b.id < 0).length;
  assert.ok(newIDs >= 1, 'split children get new IDs');
  publish(grown);
  for (const t of grown.retired) {
    assert.ok(t.successors.length >= 1 && t.successors.every(id => id > 0));
    assert.ok(Math.abs(t.shares.reduce((s, x) => s + x, 0) - 1) < 0.2);
  }
  const ids = grown.nodes.map(b => b.id);
  assert.equal(new Set(ids).size, ids.length, 'IDs are unique');
});

test('the drift cap retires an ID whose centroid left its birth centroid', () => {
  const n = 1200, X = clustered(n, 20, 4);
  const first = buildMap(X, n, null, null, small);
  publish(first);
  // Pretend every node was born elsewhere: nothing may keep its ID.
  const elsewhere = new Map(first.nodes.map(b => [b.id, Float32Array.from(b.centroid, x => -x)]));
  const again = buildMap(X, n, asPrevious(first, elsewhere), first.leafOf, small);
  assert.equal(again.stats.levels['3'].kept, 0);
  assert.ok(again.retired.length >= first.nodes.length - 1);
});
