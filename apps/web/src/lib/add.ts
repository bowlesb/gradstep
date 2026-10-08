// Add by DOI or any link (functions/v1/add-paper, docs/architecture/PDF_UPLOADS.md §1). arXiv
// identifiers stay on the library command path (v2_begin_import), as in the native Add sheet.
// The browser has no PDF upload or device download yet, so it never claims those capabilities.
import { BackendError, functionPost } from './backend';

export type AddStatus = 'added' | 'present' | 'closed' | 'blocked' | 'link_only' | 'not_found' | 'needs_update' | 'unavailable' | 'invalid' | 'failed';
const STATUSES: readonly AddStatus[] = ['added', 'present', 'closed', 'blocked', 'link_only', 'not_found', 'needs_update', 'unavailable', 'invalid', 'failed'];

export interface AddPaperResult {
  status: AddStatus;
  paper: { title: string; year: number | null; source_id: string } | null;
  /** What a device could fetch when our servers can't (https only). */
  link: string | null;
  reason: string | null;
  title: string | null;
}

const text = (v: unknown, max: number) => typeof v === 'string' && v.length > 0 && v.length <= max && !/[\u0000-\u001f\u007f]/.test(v) ? v : null;
export const httpsLink = (v: unknown): string | null => {
  const value = text(v, 2000);
  if (!value || !/^https:\/\/[!-~]+$/.test(value)) return null;
  try { const url = new URL(value); return url.protocol === 'https:' && !url.username && !url.password ? url.href : null; } catch { return null; }
};

/** Bounded decoding: unknown statuses and malformed fields never reach the page. */
export function decodeAddResult(value: unknown): AddPaperResult {
  const v = value as Record<string, unknown> | null;
  if (!v || typeof v !== 'object' || !STATUSES.includes(v.status as AddStatus)) throw new BackendError('invalid_response');
  const p = v.paper as Record<string, unknown> | null | undefined;
  const title = p ? text(p.title, 2000) : null, source = p ? text(p.source_id, 200) : null;
  return {
    status: v.status as AddStatus,
    paper: title && source ? { title, source_id: source, year: Number.isInteger(p!.year) && (p!.year as number) > 999 && (p!.year as number) < 10_000 ? p!.year as number : null } : null,
    link: httpsLink(v.link), reason: text(v.reason, 64), title: text(v.title, 500),
  };
}

export async function addPaper(account: string, query: string, signal?: AbortSignal): Promise<AddPaperResult> {
  const body = { operation_id: crypto.randomUUID(), query: [...query.trim()].slice(0, 2000).join(''), capabilities: ['web_import'] };
  return decodeAddResult(await functionPost('add-paper', body, { account, signal, maximum: 65_536, timeout: 40_000 }));
}

export interface AddOutcome { status: AddStatus; message: string; link: string | null; finished: boolean }
const ELSEWHERE = 'Gradstep on iPhone, iPad or Mac';

/** The reader's words for an outcome (native AddOutcome.from, adapted to what the browser can do). */
export function addOutcome(result: AddPaperResult): AddOutcome {
  const named = result.paper ? `“${result.paper.title}”` : null;
  const outcome = (message: string, finished = false): AddOutcome => ({ status: result.status, message, link: result.link, finished });
  switch (result.status) {
    case 'added': return outcome(`Added ${named ?? 'the paper'}. It’s being prepared to read.`, true);
    case 'present': return outcome(`${named ?? 'This paper'} is already in your library.`, true);
    case 'closed': return outcome(`${named ?? 'This paper'} isn’t openly available. If you have the PDF, upload it from ${ELSEWHERE} and it will be converted for you alone.`);
    case 'blocked': {
      const why = result.reason === 'pdf_restricted' ? 'This paper’s website needs a sign-in or subscription, so our servers can’t download it.'
        : result.reason === 'source_unavailable' ? 'The paper’s website isn’t responding to our servers.'
          : 'The paper’s website blocked the download from our servers.';
      return outcome(`${why} Your own device may still be able to download it: add it from ${ELSEWHERE}.`);
    }
    case 'link_only': return outcome(`${result.title ? `“${result.title}”` : 'This link'} isn’t a paper we could identify, but it leads to a PDF. Downloading it on this device isn’t available in the browser yet; add it from ${ELSEWHERE}.`);
    case 'not_found': return outcome('Couldn’t find a paper for this. Check the ID or link.');
    case 'needs_update': return outcome(`${named ?? 'This paper'} needs the latest version of Gradstep. Reload this page.`);
    case 'invalid': return outcome('Enter an arXiv ID, a DOI, or a link to a paper or PDF.');
    default: return outcome('Couldn’t add it right now. Check your connection and try again.');
  }
}

/** Errors from the request itself (not an outcome). */
export function addFailure(error: unknown): string {
  const code = error instanceof BackendError ? error.code : '';
  if (code === 'rate_limited' || code === 'request_rate_limit') return 'Too many papers added in a short time. Try again in a few minutes.';
  if (code === 'connection') return 'Couldn’t reach Gradstep. Check your connection and try again.';
  return 'Couldn’t add it right now. Try again.';
}
