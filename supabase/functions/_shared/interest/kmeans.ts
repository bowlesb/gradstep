// Spherical k-means on unit vectors (docs/architecture/INTEREST_INDEX.md §2): Lloyd's iterations with normalised
// centroids, k-means++ seeding from a seeded PRNG, the best of `nInit` runs by inertia, empty clusters reseeded at the
// point farthest from every centroid. Deterministic for a fixed seed and input order.
import { DIM } from './codec.ts';

/** Row-major unit vectors: row i is data.subarray(i * DIM, (i + 1) * DIM). */
export type Matrix = Float32Array;

export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function dot(a: Float32Array, ao: number, b: Float32Array, bo: number): number {
  let s = 0;
  for (let i = 0; i < DIM; i++) s += a[ao + i] * b[bo + i];
  return s;
}

export function normalizeRows(m: Float32Array, rows: number): Float32Array {
  for (let r = 0; r < rows; r++) {
    let n = 0;
    for (let i = 0; i < DIM; i++) n += m[r * DIM + i] ** 2;
    n = Math.sqrt(n);
    if (n > 0) for (let i = 0; i < DIM; i++) m[r * DIM + i] /= n;
  }
  return m;
}

/** Mean of the given rows, normalised. */
export function centroidOf(X: Matrix, rows: ArrayLike<number>): Float32Array {
  const c = new Float32Array(DIM);
  for (let j = 0; j < rows.length; j++) { const o = rows[j] * DIM; for (let i = 0; i < DIM; i++) c[i] += X[o + i]; }
  return normalizeRows(c, 1);
}

export interface KMeansResult { labels: Int32Array; centroids: Float32Array; k: number; inertia: number }

interface Options { seed: number; nInit?: number; maxIter?: number; init?: Float32Array[] }

/** Clusters the rows `idx` of X into k groups. With `init`, one run starts from those centroids (warm start). */
export function sphericalKMeans(X: Matrix, idx: ArrayLike<number>, k: number, options: Options): KMeansResult {
  const n = idx.length;
  k = Math.max(1, Math.min(k, n));
  if (options.init) {
    const init = options.init.slice(0, k);
    const C = new Float32Array(init.length * DIM);
    init.forEach((c, j) => C.set(c, j * DIM));
    return lloyd(X, idx, C, init.length, options.maxIter ?? 50);
  }
  let best: KMeansResult | null = null;
  const random = mulberry32(options.seed);
  for (let run = 0; run < (options.nInit ?? 4); run++) {
    const result = lloyd(X, idx, plusPlus(X, idx, k, random), k, options.maxIter ?? 50);
    if (!best || result.inertia < best.inertia) best = result;
  }
  return best!;
}

function plusPlus(X: Matrix, idx: ArrayLike<number>, k: number, random: () => number): Float32Array {
  const n = idx.length, C = new Float32Array(k * DIM), d2 = new Float64Array(n).fill(Infinity);
  let pick = Math.floor(random() * n);
  for (let j = 0; j < k; j++) {
    C.set(X.subarray(idx[pick] * DIM, idx[pick] * DIM + DIM), j * DIM);
    let total = 0;
    for (let p = 0; p < n; p++) {
      const d = 2 - 2 * dot(X, idx[p] * DIM, C, j * DIM);
      if (d < d2[p]) d2[p] = d;
      total += Math.max(0, d2[p]);
    }
    if (j + 1 === k) break;
    let r = random() * total;
    pick = n - 1;
    for (let p = 0; p < n; p++) { r -= Math.max(0, d2[p]); if (r <= 0) { pick = p; break; } }
  }
  return C;
}

function lloyd(X: Matrix, idx: ArrayLike<number>, C: Float32Array, k: number, maxIter: number): KMeansResult {
  const n = idx.length, labels = new Int32Array(n).fill(-1), best = new Float64Array(n);
  let inertia = 0;
  for (let iter = 0; iter < maxIter; iter++) {
    let changed = 0;
    inertia = 0;
    for (let p = 0; p < n; p++) {
      const o = idx[p] * DIM;
      let bj = 0, bs = -Infinity;
      for (let j = 0; j < k; j++) { const s = dot(X, o, C, j * DIM); if (s > bs) { bs = s; bj = j; } }
      if (labels[p] !== bj) { labels[p] = bj; changed++; }
      best[p] = bs;
      inertia += 2 - 2 * bs;
    }
    // New centroids; an empty cluster takes the point farthest from its centroid.
    const sums = new Float32Array(k * DIM), counts = new Int32Array(k);
    for (let p = 0; p < n; p++) {
      const o = idx[p] * DIM, j = labels[p];
      counts[j]++;
      for (let i = 0; i < DIM; i++) sums[j * DIM + i] += X[o + i];
    }
    for (let j = 0; j < k; j++) {
      if (counts[j] === 0) {
        let far = 0;
        for (let p = 1; p < n; p++) if (best[p] < best[far]) far = p;
        sums.set(X.subarray(idx[far] * DIM, idx[far] * DIM + DIM), j * DIM);
        best[far] = Infinity;
        labels[far] = j;
        changed++;
      }
    }
    C = normalizeRows(sums, k);
    if (changed === 0) break;
  }
  return { labels, centroids: C, k, inertia };
}
