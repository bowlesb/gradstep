// What a server paper copy is, and how to count them from Storage itself (docs/architecture/DATA_HANDLING_AND_COSTS.md
// "Server paper copies: retired"). Shared by scripts/delete-paper-copies.mjs and the storage.no-papers workflow check.
// Plain fetch against the Storage API with the service key the caller passes; nothing is printed here.

// Every object in these buckets is a copy of a paper (or a piece of one): the old server pipeline's PDFs, its Mathpix
// output and reader bundles, and PDF upload chunks.
export const PAPER_BUCKETS = ['paper-assets', 'paper-uploads'];
// Not paper copies, and never touched by the retirement: episode audio and transcripts, the text a device sends for an
// episode (deleted once the episode is made), report screenshots. Counted before and after as controls.
export const CONTROL_BUCKETS = ['podcast-assets', 'private-content', 'support'];
// The paths the pipeline wrote (paper-assets) and the upload chunks (paper-uploads: <account>/<digest>/<part>).
const PAPER_PATHS = {
  'paper-assets': /^(originals\/[0-9a-f]{40,64}\.pdf|private\/[0-9a-f-]{36}\/originals\/[^/]+|raw\/[0-9a-f]{64}\/[^/]+|reader\/[0-9a-f]{64}\/(?:[^/]+|assets\/[^/]+))$/,
  'paper-uploads': /^[0-9a-f-]{36}\/[^/]+(?:\/[^/]+)*$/,
};
export const isPaperCopyPath = (bucket, path) => PAPER_PATHS[bucket]?.test(path) ?? false;

const MAX_FOLDERS = 20_000, MAX_FILES = 50_000;

/** Every object in a bucket (folders listed recursively, bounded), with its size. A missing bucket is an error. */
export async function listBucket(url, key, bucket, { signal } = {}) {
  const files = [], folders = [''];
  let visited = 0;
  while (folders.length) {
    if (++visited > MAX_FOLDERS) throw new Error(`${bucket}: listing exceeded ${MAX_FOLDERS} folders`);
    const folder = folders.pop();
    for (let offset = 0; ; offset += 1000) {
      const response = await fetch(`${url.replace(/\/$/, '')}/storage/v1/object/list/${encodeURIComponent(bucket)}`, {
        method: 'POST', redirect: 'error', signal: signal ?? AbortSignal.timeout(30_000),
        headers: { apikey: key, Authorization: `Bearer ${key}`, 'content-type': 'application/json' },
        body: JSON.stringify({ prefix: folder, limit: 1000, offset, sortBy: { column: 'name', order: 'asc' } }) });
      const text = await response.text();
      if (response.status !== 200) throw new Error(`${bucket}: listing answered HTTP ${response.status}`);
      const page = JSON.parse(text);
      if (!Array.isArray(page)) throw new Error(`${bucket}: listing was not a list`);
      for (const entry of page) {
        const path = folder ? `${folder}/${entry.name}` : entry.name;
        if (entry.id === null || entry.id === undefined) folders.push(path);
        else {
          if (files.length >= MAX_FILES) throw new Error(`${bucket}: listing exceeded ${MAX_FILES} files`);
          files.push({ bucket, path, bytes: Number(entry.metadata?.size ?? 0) });
        }
      }
      if (page.length < 1000) break;
    }
  }
  return files;
}

/** Counts and bytes per bucket and first path segment ("prefix"). */
export function summarize(objects) {
  const buckets = {};
  for (const o of objects) {
    const b = buckets[o.bucket] ??= { objects: 0, bytes: 0, prefixes: {} };
    const prefix = o.path.split('/')[0];
    const p = b.prefixes[prefix] ??= { objects: 0, bytes: 0 };
    b.objects++; b.bytes += o.bytes; p.objects++; p.bytes += o.bytes;
  }
  return buckets;
}

/** Removes the given paths from one bucket (Storage's own delete, 100 at a time). Returns how many Storage reported. */
export async function removeObjects(url, key, bucket, paths, { signal } = {}) {
  let removed = 0;
  for (let i = 0; i < paths.length; i += 100) {
    const batch = paths.slice(i, i + 100);
    const response = await fetch(`${url.replace(/\/$/, '')}/storage/v1/object/${encodeURIComponent(bucket)}`, {
      method: 'DELETE', redirect: 'error', signal: signal ?? AbortSignal.timeout(60_000),
      headers: { apikey: key, Authorization: `Bearer ${key}`, 'content-type': 'application/json' }, body: JSON.stringify({ prefixes: batch }) });
    const text = await response.text();
    if (response.status !== 200) throw new Error(`${bucket}: delete answered HTTP ${response.status}`);
    const done = JSON.parse(text);
    removed += Array.isArray(done) ? done.length : 0;
  }
  return removed;
}

export const megabytes = bytes => `${(bytes / 1e6).toFixed(1)} MB`;
