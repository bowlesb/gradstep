// The topic map: nested spherical k-means with stable, append-only node IDs (docs/architecture/INTEREST_INDEX.md §2).
//
// Version 1 is a cold build (20 / ~n÷150 / ~n÷40, as tools/interest-eval/topic_map.py). Every later build is warm-started
// from the previous version: each previous node is re-homed under the new parent its centroid descends to and is one
// seed, except that a node holding >= 2x its target splits (two seeds) and one below 1/4 merges (no seed). A new node
// keeps the ID of the node that seeded it when membership Jaccard (over papers in both corpora) >= keepJaccard,
// centroid cos >= keepCos and it is within driftMax of its birth centroid; after a split the closer child keeps it.
// Every other node gets a new ID; every previous node not kept is retired with successors (where its papers went).
// Membership is canonical by descent: nearest level-1 centroid, then the nearest child, then the nearest leaf.
import { DIM } from './codec.ts';
import { centroidOf, dot, sphericalKMeans, type Matrix } from './kmeans.ts';

export interface MapParams {
  topK: number; midSize: number; leafSize: number; keepJaccard: number; keepCos: number; driftMax: number;
}
export const DEFAULT_PARAMS: MapParams = { topK: 20, midSize: 150, leafSize: 40, keepJaccard: 0.5, keepCos: 0.9, driftMax: 0.05 };

export interface PreviousNode { id: number; level: 1 | 2 | 3; parent: number | null; centroid: Float32Array; birth: Float32Array }
/** A built node. `id` is the kept previous ID, or a negative placeholder for a new node (allocated at publication). */
export interface BuiltNode { id: number; level: 1 | 2 | 3; parent: number | null; centroid: Float32Array; members: number[]; keptFrom: number | null }
export interface Retired { id: number; level: number; successors: number[]; shares: number[] }
export interface BuildResult {
  nodes: BuiltNode[]; leafOf: Int32Array; retired: Retired[];
  stats: { kind: 'cold' | 'warm'; papers: number; levels: Record<string, { previous: number; nodes: number; kept: number; kept_share: number | null }>; splits: number; merges: number; cohesion: number };
}

const cos = (a: Float32Array, b: Float32Array) => dot(a, 0, b, 0);

function nearest(X: Matrix, row: number, candidates: { centroid: Float32Array }[]): number {
  let best = -1, bs = -Infinity;
  for (let j = 0; j < candidates.length; j++) {
    const s = dot(X, row * DIM, candidates[j].centroid, 0);
    if (s > bs) { bs = s; best = j; }
  }
  return best;
}

/** The leaf a fingerprint descends to: nearest level-1 node, its nearest child, that node's nearest leaf. */
export function descend<T extends { id: number; level: number; parent: number | null; centroid: Float32Array }>(
  v: Float32Array, nodes: T[], children = childIndex(nodes)): T {
  let level = nodes.filter(n => n.level === 1);
  let pick: T | null = null;
  for (let depth = 1; depth <= 3 && level.length; depth++) {
    let bs = -Infinity;
    for (const n of level) { const s = cos(v, n.centroid); if (s > bs) { bs = s; pick = n; } }
    level = children.get(pick!.id) ?? [];
  }
  return pick!;
}

export function childIndex<T extends { id: number; parent: number | null }>(nodes: T[]): Map<number, T[]> {
  const out = new Map<number, T[]>();
  for (const n of nodes) if (n.parent !== null) { const list = out.get(n.parent) ?? []; list.push(n); out.set(n.parent, list); }
  return out;
}

/**
 * Builds a map over the rows of X (unit fingerprints, row order = corpus order sorted by source_id).
 * `previousLeaf[r]` is row r's leaf in the previous version (or -1 when it was not assigned).
 */
export function buildMap(X: Matrix, n: number, previous: PreviousNode[] | null, previousLeaf: Int32Array | null,
  params: MapParams = DEFAULT_PARAMS): BuildResult {
  let next = -1;
  const fresh = () => next--;
  const all = Array.from({ length: n }, (_, i) => i);
  const built: BuiltNode[] = [];
  let splits = 0, merges = 0;

  if (!previous || previous.length === 0) {
    // Cold: as topic_map.build_tree, then canonical descent.
    const l1 = sphericalKMeans(X, all, params.topK, { seed: 0, nInit: 4 });
    for (let g = 0; g < l1.k; g++) {
      const m1 = all.filter((_, p) => l1.labels[p] === g);
      if (!m1.length) continue;
      const n1: BuiltNode = { id: fresh(), level: 1, parent: null, centroid: centroidOf(X, m1), members: m1, keptFrom: null };
      built.push(n1);
      const l2 = sphericalKMeans(X, m1, Math.max(2, Math.round(m1.length / params.midSize)), { seed: 1, nInit: 4 });
      for (let g2 = 0; g2 < l2.k; g2++) {
        const m2 = m1.filter((_, p) => l2.labels[p] === g2);
        if (!m2.length) continue;
        const n2: BuiltNode = { id: fresh(), level: 2, parent: n1.id, centroid: centroidOf(X, m2), members: m2, keptFrom: null };
        built.push(n2);
        const k3 = Math.max(1, Math.round(m2.length / params.leafSize));
        const l3 = k3 > 1 ? sphericalKMeans(X, m2, k3, { seed: 2, nInit: 4 }) : { labels: new Int32Array(m2.length), k: 1 };
        for (let g3 = 0; g3 < l3.k; g3++) {
          const m3 = m2.filter((_, p) => l3.labels[p] === g3);
          if (m3.length) built.push({ id: fresh(), level: 3, parent: n2.id, centroid: centroidOf(X, m3), members: m3, keptFrom: null });
        }
      }
    }
    return finish(X, n, built, null, null, params, 'cold', 0, 0);
  }

  // Warm: previous memberships over this corpus (rows whose previous leaf is known).
  const prevById = new Map(previous.map(p => [p.id, p]));
  const prevMembers = new Map<number, Set<number>>();
  if (previousLeaf) {
    for (let r = 0; r < n; r++) {
      let id = previousLeaf[r];
      while (id >= 0 && prevById.has(id)) {
        let set = prevMembers.get(id);
        if (!set) prevMembers.set(id, set = new Set());
        set.add(r);
        const parent = prevById.get(id)!.parent;
        id = parent === null ? -1 : parent;
      }
    }
  }
  const prevLevel = (l: number) => previous.filter(p => p.level === l);

  // Level 1: the previous level-1 centroids seed a fixed number of nodes.
  const p1 = prevLevel(1);
  const l1 = sphericalKMeans(X, all, p1.length, { seed: 0, init: p1.map(p => p.centroid) });
  const level1: BuiltNode[] = [];
  for (let g = 0; g < l1.k; g++) {
    const m1 = all.filter((_, p) => l1.labels[p] === g);
    if (m1.length) level1.push({ id: fresh(), level: 1, parent: null, centroid: centroidOf(X, m1), members: m1, keptFrom: p1[g].id });
  }
  built.push(...level1);

  const levelDown = (level: 2 | 3, target: number, parents: BuiltNode[], seed: number) => {
    const out: BuiltNode[] = [];
    // Re-home every previous node of this level under the new parent its centroid descends to.
    const home = new Map<BuiltNode, PreviousNode[]>();
    for (const prev of prevLevel(level)) {
      let best = parents[0], bs = -Infinity;
      for (const par of parents) { const s = cos(prev.centroid, par.centroid); if (s > bs) { bs = s; best = par; } }
      const list = home.get(best) ?? []; list.push(prev); home.set(best, list);
    }
    for (const par of parents) {
      const pm = par.members;
      const olds = home.get(par) ?? [];
      const seeds: { from: PreviousNode | null; centroid: Float32Array }[] = [];
      if (!olds.length) {
        const k = Math.max(level === 2 ? 2 : 1, Math.round(pm.length / target));
        if (k > 1) { const r = sphericalKMeans(X, pm, k, { seed, nInit: 4 }); for (let j = 0; j < r.k; j++) seeds.push({ from: null, centroid: r.centroids.slice(j * DIM, j * DIM + DIM) }); }
        else seeds.push({ from: null, centroid: centroidOf(X, pm) });
      } else {
        const counts = new Map<PreviousNode, number[]>(olds.map(o => [o, []]));
        for (const r of pm) counts.get(olds[nearest(X, r, olds)])!.push(r);
        for (const o of olds) {
          const mine = counts.get(o)!;
          if (mine.length >= 2 * target) {
            const r = sphericalKMeans(X, mine, 2, { seed: seed + 7, nInit: 4 });
            for (let j = 0; j < r.k; j++) seeds.push({ from: o, centroid: r.centroids.slice(j * DIM, j * DIM + DIM) });
            splits++;
          } else if (mine.length < Math.max(2, Math.floor(target / 4))) merges++;
          else seeds.push({ from: o, centroid: o.centroid });
        }
        if (!seeds.length) seeds.push({ from: null, centroid: centroidOf(X, pm) });
      }
      const result = seeds.length > 1 ? sphericalKMeans(X, pm, seeds.length, { seed, init: seeds.map(s => s.centroid) })
        : { labels: new Int32Array(pm.length), k: 1 };
      for (let g = 0; g < result.k; g++) {
        const mm = pm.filter((_, p) => result.labels[p] === g);
        if (mm.length) out.push({ id: fresh(), level, parent: par.id, centroid: centroidOf(X, mm), members: mm, keptFrom: seeds[g].from?.id ?? null });
      }
    }
    return out;
  };
  const level2 = levelDown(2, params.midSize, level1, 1);
  built.push(...level2);
  built.push(...levelDown(3, params.leafSize, level2, 2));
  return finish(X, n, built, previous, prevMembers, params, 'warm', splits, merges);
}

function finish(X: Matrix, n: number, built: BuiltNode[], previous: PreviousNode[] | null,
  prevMembers: Map<number, Set<number>> | null, params: MapParams, kind: 'cold' | 'warm', splits: number, merges: number): BuildResult {
  // Canonical membership by descent over the built centroids, then centroids recomputed once from it.
  const children = childIndex(built);
  const leafOf = new Int32Array(n);
  const members = new Map<BuiltNode, number[]>(built.map(b => [b, []]));
  const byId = new Map(built.map(b => [b.id, b]));
  for (let r = 0; r < n; r++) {
    const v = X.subarray(r * DIM, r * DIM + DIM);
    const leaf = descend(v, built, children);
    leafOf[r] = leaf.id;
    for (let node: BuiltNode | undefined = leaf; node; node = node.parent === null ? undefined : byId.get(node.parent)) members.get(node)!.push(r);
  }
  // Drop nodes descent left empty (their parents keep the papers).
  const nodes = built.filter(b => members.get(b)!.length > 0);
  for (const b of nodes) { b.members = members.get(b)!; b.centroid = centroidOf(X, b.members); }

  // IDs: keep, or new; previous nodes not kept retire with successors.
  const levels: BuildResult['stats']['levels'] = {};
  const retired: Retired[] = [];
  const shared = new Set<number>();
  if (prevMembers) for (const set of prevMembers.values()) for (const r of set) shared.add(r);
  for (const level of [1, 2, 3] as const) {
    const mine = nodes.filter(b => b.level === level);
    const prevs = (previous ?? []).filter(p => p.level === level);
    const claims = new Map<number, { node: BuiltNode; jaccard: number }>();
    for (const b of mine) {
      if (b.keptFrom === null || !prevMembers) continue;
      const prev = previous!.find(p => p.id === b.keptFrom)!;
      const a = prevMembers.get(prev.id) ?? new Set<number>();
      const bm = b.members.filter(r => shared.has(r));
      let inter = 0;
      for (const r of bm) if (a.has(r)) inter++;
      const jaccard = inter / Math.max(1, a.size + bm.length - inter);
      const ok = jaccard >= params.keepJaccard && cos(b.centroid, prev.centroid) >= params.keepCos
        && cos(b.centroid, prev.birth) >= 1 - params.driftMax;
      const current = claims.get(prev.id);
      if (ok && (!current || jaccard > current.jaccard)) claims.set(prev.id, { node: b, jaccard });
    }
    const keptNodes = new Set<BuiltNode>();
    for (const [prevId, { node }] of claims) { remap(nodes, node.id, prevId); keptNodes.add(node); }
    for (const b of mine) if (!keptNodes.has(b)) b.keptFrom = null;
    for (const p of prevs) {
      if (claims.has(p.id)) continue;
      const former = prevMembers?.get(p.id) ?? new Set<number>();
      const where = new Map<number, number>();
      for (const b of mine) { let c = 0; for (const r of b.members) if (former.has(r)) c++; if (c) where.set(b.id, c); }
      const total = [...where.values()].reduce((s, c) => s + c, 0);
      const ranked = [...where.entries()].sort((x, y) => y[1] - x[1]).filter(([, c]) => total && c / total >= 0.1);
      retired.push({ id: p.id, level, successors: ranked.map(([id]) => id), shares: ranked.map(([, c]) => Math.round(c / total * 1000) / 1000) });
    }
    levels[String(level)] = { previous: prevs.length, nodes: mine.length, kept: claims.size,
      kept_share: prevs.length ? Math.round(claims.size / prevs.length * 1000) / 1000 : null };
  }
  // Leaf ids may have been remapped: rebuild the per-row leaf from the final nodes.
  for (const b of nodes) if (b.level === 3) for (const r of b.members) leafOf[r] = b.id;
  let cohesion = 0, leaves = 0;
  for (const b of nodes) if (b.level === 3) {
    let s = 0;
    for (const r of b.members) s += dot(X, r * DIM, b.centroid, 0);
    cohesion += s / b.members.length; leaves++;
  }
  return { nodes, leafOf, retired, stats: { kind, papers: n, levels, splits, merges, cohesion: Math.round(cohesion / Math.max(1, leaves) * 10000) / 10000 } };
}

/** Renames node `from` to `to` (and its children's parent pointers). */
function remap(nodes: BuiltNode[], from: number, to: number) {
  for (const b of nodes) { if (b.id === from) b.id = to; if (b.parent === from) b.parent = to; }
}

/** Replaces every placeholder (negative) ID with an allocated one, in nodes, parents, leaves and successors. */
export function assignIDs(result: BuildResult, allocated: number[]): void {
  const placeholders = result.nodes.filter(b => b.id < 0).map(b => b.id);
  if (allocated.length !== placeholders.length) throw new Error('interest_node_ids');
  const map = new Map(placeholders.map((p, i) => [p, allocated[i]]));
  const real = (id: number) => (id < 0 ? map.get(id)! : id);
  for (const b of result.nodes) { b.id = real(b.id); if (b.parent !== null) b.parent = real(b.parent); }
  for (let r = 0; r < result.leafOf.length; r++) result.leafOf[r] = real(result.leafOf[r]);
  for (const t of result.retired) t.successors = t.successors.map(real);
}
