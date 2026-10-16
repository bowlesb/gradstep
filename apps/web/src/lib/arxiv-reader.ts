import { fromBase64, fromUtf8, toBase64, type Bytes } from './bytes';
import { verifyBundle, type VerifiedBundle } from './bundle';
import { sourceReference, type SourcePaperReference } from './events';
import { arxivPreparationMessage } from './arxiv-reader-error';
import { buildPaperContext, PAPER_CONTEXT_FORMAT } from './paper-context';
/** `kind`: what the reader offers instead (build 57, 2610.20399): 'no-html' (arXiv has no HTML for this version: its PDF
 * only), 'network' (arXiv busy, refused or unreachable: its PDF would fail the same way), 'prepare' (its PDF, beside Try again). */
export class ArxivReaderError extends Error {
 constructor(message: string, readonly kind: 'no-html' | 'network' | 'prepare' | 'asset' = 'prepare') { super(message); }
}

/** Who hears about a page this browser downloaded to prepare a paper (source-metadata.ts, while the server asks for
 * device-read metadata; docs/architecture/ARXIV_DEVICE_ONLY.md §5.3). */
export interface ArxivSourceObserver { source(ref: SourcePaperReference, html: Bytes): void }
let sourceObserver: ArxivSourceObserver | null = null;
export function observeArxivSources(observer: ArxivSourceObserver | null): () => void {
 sourceObserver = observer;
 return () => { if (sourceObserver === observer) sourceObserver = null; };
}

/** Acquisition pacing. A paper's HTML document request is spaced like a new page visit; that page's
 * own declared assets then load together, bounded, the way a browser loads the images of one page.
 * A Retry-After from arXiv pauses every request from this page; a refusal (403) stops every arXiv request from this
 * browser for a day, kept across reloads (owner, 2026-10-15; docs/architecture/ARXIV_DEVICE_ONLY.md §5.1, §5.9). */
export const ARXIV_PACING = Object.freeze({ documentSpacingMs: 3000, assetConcurrency: 4, requestTimeoutMs: 90_000, busyLimitMs: 60_000 });
export const ARXIV_LIMITS = Object.freeze({ sourceBytes: 8_388_608, assetBytes: 16_777_216, totalBytes: 41_943_040, assets: 512 });
const BUSY = 'arXiv is busy. Try preparing this paper again later.';
const UNAVAILABLE = 'arXiv didn’t return this version’s HTML completely. You can still open its PDF on this device.';
const NO_HTML = 'arXiv couldn’t make a web version of this paper, which the reader needs. Its PDF opens from arXiv in a new tab.';
const TOO_LARGE = 'This paper exceeds the device reader’s preparation limits.';
const UNREACHABLE = 'Couldn’t retrieve this paper from arXiv. Check your connection and try again.';
const REFUSED = 'arXiv refused requests from this browser, so Gradstep won’t ask arXiv from here again for a day. Papers already prepared in this tab still open.';
export const ARXIV_REFUSAL = Object.freeze({ pauseMs: 86_400_000, key: 'gradstep.arxiv.refused-until' });

let nextDocumentRequest = 0;
let busyUntil = 0;
let refusedUntil = 0;
/** Fast-suite only: forget this page's pacing state. */
export function resetArxivPacing(): void { nextDocumentRequest = 0; busyUntil = 0; refusedUntil = 0; try { localStorage.removeItem(ARXIV_REFUSAL.key); } catch { /* no storage */ } }
/** Until when arXiv's last refusal stops this browser asking: this tab's own, or one another tab or an earlier visit
 * recorded. A record more than a day ahead is not one this code wrote, and is ignored. */
function refusal(now: number): number {
 let stored = 0; try { stored = Number(localStorage.getItem(ARXIV_REFUSAL.key)) || 0; } catch { /* no storage: this tab only */ }
 if (stored <= now + ARXIV_REFUSAL.pauseMs) refusedUntil = Math.max(refusedUntil, stored);
 return refusedUntil;
}

const abort = (signal: AbortSignal) => signal.throwIfAborted();
const wait = (ms: number, signal: AbortSignal) => new Promise<void>((resolve, reject) => {
 abort(signal); if (ms <= 0) { resolve(); return; }
 const stop = () => { clearTimeout(timer); reject(signal.reason); };
 const timer = setTimeout(() => { signal.removeEventListener('abort', stop); resolve(); }, Math.max(0, ms)); signal.addEventListener('abort', stop, { once: true });
});
export const arxivHTMLURL = (ref: SourcePaperReference): string => { sourceReference(ref); return `https://arxiv.org/html/${ref.sourceID}v${ref.revision}`; };
export function admitsArxivAsset(url: string, base: string): boolean {
 try { const u = new URL(url); return u.origin === 'https://arxiv.org' && !u.username && !u.password && !u.search && !u.hash &&
  !/%/.test(url) && !url.includes('\\') && u.href === url && u.pathname.startsWith(new URL(base).pathname + '/') && /\.(png|jpe?g|svg)$/i.test(u.pathname); } catch { return false; }
}
/** One bounded GET of an exact official URL. Exported for the fast suite. */
export async function retrieveArxiv(url: string, maximum: number, html: boolean, parentSignal: AbortSignal): Promise<Bytes> {
 abort(parentSignal);
 const now = Date.now();
 if (refusal(now) > now) throw new ArxivReaderError(REFUSED, 'network');
 if (busyUntil - now > ARXIV_PACING.busyLimitMs) throw new ArxivReaderError(BUSY, 'network');
 let scheduled = Math.max(now, busyUntil);
 if (html) { scheduled = Math.max(scheduled, nextDocumentRequest); nextDocumentRequest = scheduled + ARXIV_PACING.documentSpacingMs; }
 await wait(scheduled - now, parentSignal);
 const signal = AbortSignal.any([parentSignal, AbortSignal.timeout(ARXIV_PACING.requestTimeoutMs)]);
 let response: Response;
 try { response = await fetch(url, { credentials: 'omit', redirect: 'error', cache: 'no-store', referrerPolicy: 'no-referrer', signal }); }
 catch { abort(parentSignal); throw new ArxivReaderError(UNREACHABLE, 'network'); }
 if (response.status === 403) {
  refusedUntil = Date.now() + ARXIV_REFUSAL.pauseMs;
  try { localStorage.setItem(ARXIV_REFUSAL.key, String(refusedUntil)); } catch { /* no storage: this tab only */ }
  await response.body?.cancel(); throw new ArxivReaderError(REFUSED, 'network');
 }
 if ([429, 503].includes(response.status)) {
  const retry = response.headers.get('retry-after'), seconds = retry && /^\d+$/.test(retry) ? Number(retry) : Math.max(60, (Date.parse(retry ?? '') - Date.now()) / 1000 || 60);
  busyUntil = Math.max(busyUntil, Date.now() + Math.min(86400, Math.max(3, seconds)) * 1000);
  nextDocumentRequest = Math.max(nextDocumentRequest, busyUntil);
  await response.body?.cancel(); throw new ArxivReaderError(BUSY, 'network');
 }
 const type = response.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
 if (!response.ok || response.url !== url || !response.body || !(html ? ['text/html', 'application/xhtml+xml'] : ['image/png', 'image/jpeg', 'image/svg+xml']).includes(type ?? '')) {
  await response.body?.cancel();
  // The paper's own page missing (as the native reader): arXiv has no HTML for this version.
  if (html && [404, 410].includes(response.status)) throw new ArxivReaderError(NO_HTML, 'no-html');
  // One image arXiv doesn't serve (not found, not an image): that figure's loss, not the paper's.
  if (!html && (response.status < 500 || response.ok)) throw new ArxivReaderError(UNAVAILABLE, 'asset');
  throw new ArxivReaderError(UNAVAILABLE);
 }
 // An image too large on its own is that figure's loss; one that only overruns what is left of the paper's budget isn't.
 const tooLarge = () => new ArxivReaderError(TOO_LARGE, !html && maximum >= ARXIV_LIMITS.assetBytes ? 'asset' : 'prepare');
 if (Number(response.headers.get('content-length') ?? 0) > maximum) { await response.body.cancel(); throw tooLarge(); }
 const reader = response.body.getReader(), chunks: Uint8Array[] = []; let size = 0;
 try { while (true) { abort(signal); const { done, value } = await reader.read(); if (done) break; size += value.length; if (size > maximum) throw tooLarge(); chunks.push(value); } }
 finally { await reader.cancel().catch(() => {}); }
 const bytes = new Uint8Array(size); let offset = 0; for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; } return bytes;
}
export type ArxivAssetInput = { url: string; base64: string } | { url: string; missing: true };
/** The declared assets of one paper, in declaration order, at most `assetConcurrency` in flight and within
 * `budget` bytes in total. An image arXiv doesn't serve is `missing` (its figure says so); any other failure stops
 * the others. Exported for the fast suite. */
export async function fetchArxivAssets(urls: unknown, baseURL: string, budget: number, parentSignal: AbortSignal, progress?: (fraction: number) => void): Promise<ArxivAssetInput[]> {
 if (!Array.isArray(urls) || urls.length > ARXIV_LIMITS.assets || new Set(urls).size !== urls.length || !urls.every(u => typeof u === 'string' && admitsArxivAsset(u, baseURL))) throw new ArxivReaderError('Invalid paper assets.');
 const assets = urls as string[], inputs: ArxivAssetInput[] = new Array(assets.length);
 const local = new AbortController(), signal = AbortSignal.any([parentSignal, local.signal]);
 let total = 0, done = 0, next = 0;
 const worker = async () => {
  while (next < assets.length) {
   abort(signal);
   const index = next++, url = assets[index];
   let bytes: Bytes;
   try { bytes = await retrieveArxiv(url, Math.min(ARXIV_LIMITS.assetBytes, budget - total), false, signal); }
   catch (error) {
    if (!(error instanceof ArxivReaderError && error.kind === 'asset')) throw error;
    inputs[index] = { url, missing: true }; done++; progress?.(done / (assets.length + 1)); continue;
   }
   total += bytes.length; if (total > budget) throw new ArxivReaderError(TOO_LARGE);
   inputs[index] = { url, base64: toBase64(bytes) }; done++; progress?.(done / (assets.length + 1));
  }
 };
 try { await Promise.all(Array.from({ length: Math.min(ARXIV_PACING.assetConcurrency, assets.length) }, worker)); }
 catch (error) { local.abort(error); throw error; }
 return inputs;
}

interface Preparation { promise: Promise<VerifiedBundle>; controller: AbortController; waiters: number; progress: Set<(fraction: number) => void>; last?: number }
/** One preparation per exact source revision at a time: the reader and a paper question asked meanwhile share the
 * same acquisition and compilation. The shared work stops only when every caller has given up. Exported for the fast suite. */
export function shareInflight<T extends Preparation>(registry: Map<string, T>, key: string, start: (signal: AbortSignal, progress: (fraction: number) => void) => Promise<VerifiedBundle>,
 signal: AbortSignal, progress?: (fraction: number) => void): Promise<VerifiedBundle> {
 abort(signal);
 let entry = registry.get(key);
 if (!entry) {
  const controller = new AbortController(), listeners = new Set<(fraction: number) => void>();
  const created = { controller, waiters: 0, progress: listeners } as T;
  created.promise = start(controller.signal, fraction => { created.last = fraction; for (const listener of [...listeners]) listener(fraction); });
  const forget = () => { if (registry.get(key) === created) registry.delete(key); };
  created.promise.then(forget, forget);
  registry.set(key, created); entry = created;
 }
 const shared = entry;
 shared.waiters++; if (progress) { shared.progress.add(progress); if (shared.last !== undefined) progress(shared.last); }
 return new Promise<VerifiedBundle>((resolve, reject) => {
  let settled = false;
  const leave = () => { if (settled) return; settled = true; shared.waiters--; if (progress) shared.progress.delete(progress); signal.removeEventListener('abort', onAbort); };
  const onAbort = () => { leave(); if (shared.waiters === 0) shared.controller.abort(signal.reason); reject(signal.reason); };
  signal.addEventListener('abort', onAbort, { once: true });
  shared.promise.then(value => { leave(); resolve(value); }, error => { leave(); reject(error); });
 });
}
const preparations = new Map<string, Preparation>();

export interface ArxivPrepareOptions { /** The library's author names and title for this paper (`ArxivConvertOptions`). */ authors?: readonly string[]; title?: string }
async function prepare(ref: SourcePaperReference, signal: AbortSignal, progress: (fraction: number) => void, options: ArxivPrepareOptions): Promise<VerifiedBundle> {
 const url = arxivHTMLURL(ref);
 const html = await retrieveArxiv(url, ARXIV_LIMITS.sourceBytes, true, signal); abort(signal);
 sourceObserver?.source(ref, html);
 const { default: compiler } = await import('virtual:arxiv-compiler'); abort(signal);
 const frame = document.createElement('iframe'); frame.hidden = true; frame.sandbox.add('allow-scripts');
 frame.srcdoc = `<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src '${compiler.hash}'; img-src data:; connect-src 'none'; style-src 'none'; base-uri 'none'"><script>${compiler.script}</script>`;
 const loaded = new Promise<void>((resolve, reject) => { frame.onload = () => resolve(); frame.onerror = () => reject(new ArxivReaderError('The device compiler could not start.')); });
 document.body.append(frame);
 const call = async (method: 'assets' | 'prepare', inputs?: ArxivAssetInput[], compile?: { authors: string[]; title?: string }): Promise<unknown> => {
  abort(signal);
  return await new Promise((resolve, reject) => {
   const channel = new MessageChannel(); let timer: ReturnType<typeof setTimeout>;
   const cleanup = () => { clearTimeout(timer); channel.port1.close(); signal.removeEventListener('abort', stop); };
   const stop = () => { cleanup(); reject(signal.reason); };
   timer = setTimeout(() => { cleanup(); reject(new ArxivReaderError('Preparing this paper took too long. Try opening it again. You can still open its PDF on this device.')); }, 90000);
   signal.addEventListener('abort', stop, { once: true });
   channel.port1.onmessage = e => { cleanup(); e.data?.ok ? resolve(e.data.result) : reject(new ArxivReaderError(arxivPreparationMessage(e.data?.failure))); };
   frame.contentWindow!.postMessage({ method, source: toBase64(html), sourceID: ref.sourceID, revision: ref.revision, inputs, options: compile }, '*', [channel.port2]);
  });
 };
 try {
  await Promise.race([loaded, wait(15000, signal).then(() => { throw new ArxivReaderError('The device compiler could not start.'); })]);
  // The catalog record goes with both calls: a paper whose HTML has no `h1` or no author block is headed from it.
  const authors = (options.authors ?? []).filter(a => typeof a === 'string').slice(0, 64).map(a => a.slice(0, 256));
  const compile = { authors, ...(typeof options.title === 'string' ? { title: options.title.slice(0, 2000) } : {}) };
  const assets = await call('assets', undefined, compile);
  // One fraction for the reader: downloading (the HTML, then its assets) to 0.8, preparing (the compile) to 1.
  progress(0.12);
  const inputs = await fetchArxivAssets(assets, url, ARXIV_LIMITS.totalBytes - html.length, signal, fraction => progress(0.12 + 0.68 * fraction));
  progress(0.82);
  const p = await call('prepare', inputs, compile) as { manifest: string; manifestSHA256: string; members: { path: string; base64: string }[] };
  abort(signal);
  if (!p || typeof p.manifest !== 'string' || p.manifest.length > 349528 || !Array.isArray(p.members) || p.members.length > 512) throw new ArxivReaderError('Invalid reader bundle.');
  const members = new Map<string, Bytes>(); let total = 0;
  for (const m of p.members) { if (typeof m.path !== 'string' || typeof m.base64 !== 'string' || m.base64.length > 22369624 || members.has(m.path)) throw new ArxivReaderError('Invalid reader bundle.'); const bytes = fromBase64(m.base64); total += bytes.length; if (total > ARXIV_LIMITS.totalBytes) throw new ArxivReaderError('Reader bundle is too large.'); members.set(m.path, bytes); }
  const bundle = await verifyBundle(fromBase64(p.manifest), p.manifestSHA256, members);
  const provenance = JSON.parse(fromUtf8(members.get(bundle.manifest.source.provenance_path)!));
  if (provenance.source.url !== url) throw new ArxivReaderError('Wrong source revision.'); abort(signal); progress(1); return bundle;
 } finally { frame.remove(); }
}

/** Every caller for one paper passes the same `options` (its library metadata), so a shared preparation is the same bundle. */
export function prepareArxivReader(reference: SourcePaperReference, signal: AbortSignal, progress?: (fraction: number) => void, options: ArxivPrepareOptions = {}): Promise<VerifiedBundle> {
 const ref = sourceReference(reference);
 return shareInflight(preparations, `${ref.sourceID}v${ref.revision}`, (shared, report) => prepare(ref, shared, report, options), signal, progress);
}

export function localChatContext(ref: SourcePaperReference, bundle: VerifiedBundle): import('./chat').LocalPaperContext {
 const raw = bundle.contents.get(bundle.manifest.source.provenance_path);
 if (bundle.manifest.source.kind !== 'arxiv-html' || !raw) throw new ArxivReaderError('Open this paper to prepare its HTML reader first.');
 const provenance = JSON.parse(fromUtf8(raw));
 if (provenance.source.url !== arxivHTMLURL(ref)) throw new ArxivReaderError('The reader does not match this paper revision.');
 const text = buildPaperContext(bundle.index);
 if (!text.trim() || new TextEncoder().encode(text).length > 2097152) throw new ArxivReaderError('This paper exceeds the chat context limit.');
 return { format: PAPER_CONTEXT_FORMAT, membership_id: ref.membershipID, source: 'arxiv', source_id: ref.sourceID, revision: ref.revision,
  manifest_sha256: bundle.manifestSHA256, source_sha256: bundle.manifest.source.sha256, text };
}
