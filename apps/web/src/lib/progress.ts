// Import progress in the reader's words — ported from the native ImportProgress.swift and
// LibraryMetadata.swift (docs/architecture/IMPORT_PROGRESS.md). Pure functions.
import type { Import, ProgressDetail } from './library';

export type Step = 'queued' | 'finding' | 'preparing' | 'downloading' | 'converting' | 'building' | 'waiting';

export const stepTitle: Record<Step, string> = {
  queued: 'Waiting to start', finding: 'Finding the paper', preparing: 'Getting the PDF', downloading: 'Downloading the PDF',
  converting: 'Reading equations and figures', building: 'Preparing it for reading', waiting: 'Waiting to continue',
};
export const stepTableTitle: Record<Step, string> = {
  queued: 'Waiting', waiting: 'Waiting', finding: 'Finding', preparing: 'Getting', downloading: 'Downloading', converting: 'Reading', building: 'Preparing',
};

/** Failed to download, and the server will try again by itself (migration 027): shown as under way. */
export const retryingAutomatically = (i: Import) => i.phase === 'failed' && i.error_code === 'download_retrying';

export function importStep(i: Import): Step | null {
  if (!['accepted', 'resolving', 'acquiring'].includes(i.phase)) return null;
  switch (i.progress_detail?.step) {
    case 'finding': return 'finding';
    case 'downloading': return 'downloading';
    case 'reading_equations': return 'converting';
    case 'preparing': return 'building';
    case 'waiting': return 'waiting';
  }
  switch (i.progress) {
    case 'finding': return 'finding';
    case 'downloading': return 'downloading';
    case 'converting': return 'converting';
    case 'rendering': case 'finishing': return 'building';
  }
  return i.phase === 'accepted' ? 'queued' : i.phase === 'resolving' ? 'finding' : 'preparing';
}

const FAILURES: Record<string, [string, string]> = {
  insufficient_credits: ['Not enough credits to convert this paper', 'Needs credits'],
  too_large: ['This PDF is too large to convert', 'Too large to convert'],
  pdf_invalid: ['This PDF couldn’t be read', 'PDF unreadable'],
  conversion_failed: ['Conversion failed', 'Conversion failed'],
  download_failed: ['Couldn’t download this paper', 'Download failed'],
  rate_limited: ['Couldn’t download this paper', 'Download failed'],
  download_retrying: ['Couldn’t download yet · Trying again automatically', 'Retrying soon'],
  pdf_restricted: ['This PDF needs a sign-in or subscription', 'Sign-in required'],
  source_blocked: ['The paper’s website blocked the download', 'Download blocked'],
  source_unavailable: ['The paper’s website isn’t responding', 'Site not responding'],
  not_pdf: ['The paper’s link doesn’t lead to a PDF', 'No PDF at link'],
  metadata_unavailable: ['Couldn’t get this paper’s details', 'Details unavailable'],
  license_unverified: ['Couldn’t confirm this paper’s license', 'License unconfirmed'],
};

export function importStatus(i: Import, short = false): string {
  const step = importStep(i);
  if (step) return short ? stepTableTitle[step] : stepTitle[step];
  switch (i.phase) {
    case 'source_only': return i.source === 'arxiv' ? 'Available on arXiv' : 'Available at source';
    case 'failed': { const f = FAILURES[i.error_code ?? '']; return f ? f[short ? 1 : 0] : short ? 'Import failed' : 'Couldn’t import this paper'; }
    case 'membership_conflict': return 'Not added to library';
    case 'ready': return 'Added';
    case 'cancelled': return 'Cancelled';
  }
  return 'Waiting to start';
}

export type ImportAction = 'retry' | 'credits' | 'remove';
/** The one action a stopped import offers (owner, 2026-10-07: a failed import should never just sit there). */
export function importAction(i: Import): ImportAction | null {
  if (retryingAutomatically(i)) return null;
  if (i.phase === 'failed') return i.error_code === 'insufficient_credits' ? 'credits' : i.retryable ? 'retry' : 'remove';
  if (i.phase === 'membership_conflict') return 'remove';
  return null;
}

/** When this browser received an import's current detail, and the highest percent shown in the attempt. */
export interface Mark { stateSeq: number; intent: number; detail?: ProgressDetail; receivedAt: number; floor: number }

export function shownPercent(mark: Mark, now: number): number | null {
  const detail = mark.detail;
  if (!detail) return null;
  let shown = Math.min(99, detail.percent);
  if (detail.eta_seconds && detail.eta_seconds > 0 && !detail.delayed) {
    shown += (99 - shown) * Math.min(1, Math.max(0, (now - mark.receivedAt) / 1000) / detail.eta_seconds);
  }
  return Math.min(99, Math.max(mark.floor, Math.floor(shown)));
}

export function observe(previous: Map<string, Mark>, imports: Import[], now: number): Map<string, Mark> {
  const next = new Map<string, Mark>();
  for (const i of imports) {
    if (!importStep(i)) continue;
    const old = previous.get(i.id);
    if (old && old.stateSeq === i.state_seq && old.intent === i.intent_revision) { next.set(i.id, old); continue; }
    const floor = old && old.intent === i.intent_revision ? shownPercent(old, now) ?? old.floor : 0;
    next.set(i.id, { stateSeq: i.state_seq, intent: i.intent_revision, detail: i.progress_detail, receivedAt: now, floor });
  }
  return next;
}

type TimeLeft = { kind: 'left'; seconds: number } | { kind: 'almost' } | { kind: 'typical'; seconds: number } | { kind: 'slow' };

function timeLeft(mark: Mark | undefined, now: number): TimeLeft | null {
  const detail = mark?.detail;
  if (!detail) return null;
  if (detail.delayed) return { kind: 'slow' };
  if (detail.eta_seconds === undefined) return null;
  const elapsed = Math.max(0, (now - mark!.receivedAt) / 1000), total = detail.eta_seconds;
  if (elapsed > total + Math.max(30, total)) return { kind: 'slow' };
  if (detail.pages === undefined) return { kind: 'typical', seconds: total };
  const left = total - elapsed;
  return left <= 0 ? { kind: 'almost' } : { kind: 'left', seconds: Math.ceil(left) };
}

const minutes = (s: number) => Math.max(2, Math.round(s / 60));
function timeText(t: TimeLeft, compact: boolean): string {
  switch (t.kind) {
    case 'left': {
      const s = t.seconds;
      if (s < 10) return compact ? 'A few seconds' : 'A few seconds left';
      if (s < 55) { const n = s < 30 ? Math.max(10, Math.round(s / 5) * 5) : Math.round(s / 10) * 10; return compact ? `${n} s left` : `About ${n} s left`; }
      if (s < 90) return compact ? '1 min left' : 'About a minute left';
      return compact ? `${minutes(s)} min left` : `About ${minutes(s)} min left`;
    }
    case 'almost': return 'Almost done';
    case 'typical': return t.seconds < 50 ? (compact ? 'Under a minute' : 'Usually under a minute')
      : t.seconds < 90 ? (compact ? 'About a minute' : 'Usually about a minute') : (compact ? `About ${minutes(t.seconds)} min` : `Usually about ${minutes(t.seconds)} minutes`);
    case 'slow': return 'Taking longer than usual';
  }
}

export interface ProgressView { step: Step; title: string; detail: string | null; percent: number | null; time: string | null; compactTime: string | null; label: string }

function formatBytes(bytes: number): string {
  if (bytes < 1000) return `${bytes} bytes`;
  if (bytes < 1_000_000) return `${Math.round(bytes / 1000)} KB`;
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

export function progressView(i: Import, mark: Mark | undefined, now: number): ProgressView | null {
  if (retryingAutomatically(i)) {
    return { step: 'downloading', title: 'Couldn’t download yet', detail: null, percent: null, time: 'Trying again automatically', compactTime: 'Trying again',
      label: 'Couldn’t download yet, trying again automatically' };
  }
  const step = importStep(i);
  if (!step) return null;
  const detail = i.progress_detail;
  let extra: string | null = null;
  if (detail && step === 'converting' && detail.pages) extra = detail.pages_done ? `page ${detail.pages_done} of ${detail.pages}` : detail.pages === 1 ? '1 page' : `${detail.pages} pages`;
  if (detail && step === 'downloading') extra = detail.bytes ? formatBytes(detail.bytes) : detail.pages ? (detail.pages === 1 ? '1 page' : `${detail.pages} pages`) : null;
  const percent = mark && detail ? shownPercent(mark, now) : null;
  const t = timeLeft(detail ? mark : undefined, now);
  const time = t ? timeText(t, false) : null;
  return { step, title: stepTitle[step], detail: extra, percent, time, compactTime: t ? timeText(t, true) : null,
    label: [stepTitle[step], extra, percent !== null ? `${percent} percent` : null, time?.toLowerCase()].filter(Boolean).join(', ') };
}

/** Seconds until the next import check, by seconds since polling began (native `importPollDelay`). */
export const pollDelay = (elapsed: number) => elapsed < 20 ? 1 : elapsed > 120 ? 15 : 4;
