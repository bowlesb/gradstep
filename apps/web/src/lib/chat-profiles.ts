// A chat's model, effort and length (owner request 2026-10-08) — a port of ScienceReaderCore/ChatProfiles.swift.
// The chat function accepts only its published, versioned table (`GET functions/v1/chat`, chat-profiles-v1) and holds
// and charges at the chosen model's rates; this browser only sends the choice and displays the server's estimates.
// Contract: docs/architecture/CHAT.md#models-effort-and-length.
import { functionGet } from './backend';

export type ModelChoice = 'haiku' | 'sonnet' | 'opus';
export type EffortChoice = 'low' | 'medium' | 'high';
export type LengthChoice = 'brief' | 'standard' | 'detailed';
export interface ProfileChoice { model: ModelChoice; effort: EffortChoice; length: LengthChoice }

export const MODELS: readonly ModelChoice[] = ['haiku', 'sonnet', 'opus'];
export const EFFORTS: readonly EffortChoice[] = ['low', 'medium', 'high'];
export const LENGTHS: readonly LengthChoice[] = ['brief', 'standard', 'detailed'];
/** Today's answers (and every request without a choice): Sonnet, low effort, standard length. */
export const STANDARD_PROFILE: Readonly<ProfileChoice> = Object.freeze({ model: 'sonnet', effort: 'low', length: 'standard' });

export const profileID = (c: ProfileChoice) => `${c.model}-${c.effort}-${c.length}`;
export const sameProfile = (a: ProfileChoice, b: ProfileChoice) => a.model === b.model && a.effort === b.effort && a.length === b.length;
export const isStandard = (c: ProfileChoice) => sameProfile(c, STANDARD_PROFILE);
/** A saved or reported identifier (`sonnet-low-standard`); null for anything else (`diagram_fix`, a later build's value). */
export function parseProfileID(id: string | undefined | null): ProfileChoice | null {
  if (typeof id !== 'string') return null;
  const parts = id.split('-');
  if (parts.length !== 3 || !MODELS.includes(parts[0] as ModelChoice) || !EFFORTS.includes(parts[1] as EffortChoice) || !LENGTHS.includes(parts[2] as LengthChoice)) return null;
  return { model: parts[0] as ModelChoice, effort: parts[1] as EffortChoice, length: parts[2] as LengthChoice };
}
export const isProfileChoice = (v: unknown): v is ProfileChoice => !!v && typeof v === 'object' && !Array.isArray(v)
  && MODELS.includes((v as ProfileChoice).model) && EFFORTS.includes((v as ProfileChoice).effort) && LENGTHS.includes((v as ProfileChoice).length);

interface Option { label: string; detail: string }
const BUILT_IN: { models: Record<ModelChoice, Option>; efforts: Record<EffortChoice, Option>; lengths: Record<LengthChoice, Option> } = {
  models: { haiku: { label: 'Haiku', detail: 'Fastest and cheapest' }, sonnet: { label: 'Sonnet', detail: 'Strong answers at a moderate cost' },
    opus: { label: 'Opus', detail: 'Most capable; costs the most' } },
  efforts: { low: { label: 'Low', detail: 'Thinks only when needed; quickest' }, medium: { label: 'Medium', detail: 'Thinks through harder questions' },
    high: { label: 'High', detail: 'Thinks carefully; slowest' } },
  lengths: { brief: { label: 'Brief', detail: 'A few sentences' }, standard: { label: 'Standard', detail: 'Focused answers' },
    detailed: { label: 'Detailed', detail: 'Thorough, with derivations and caveats' } },
};

export interface Estimate { low: number; high: number; max: number }
/** The server's published table, decoded tolerantly and bounded (ChatProfileTable.decode). */
export interface ProfileTable {
  version: string; defaultChoice: ProfileChoice;
  models: Partial<Record<ModelChoice, Option>>; efforts: Partial<Record<EffortChoice, Option>>; lengths: Partial<Record<LengthChoice, Option>>;
  /** Offered profiles by identifier. A choice the server doesn't list isn't offered. */
  estimates: Map<string, Estimate>; note: string | null;
}
export const SUPPORTED_VERSION = 'chat-profiles-v1';
const MAX_TABLE_BYTES = 64 * 1024;

function text(value: unknown, limit: number): string | null {
  if (typeof value !== 'string') return null;
  // Swift drops Cc/Cf scalars, trims, then counts Characters.
  const flat = value.replace(/[\p{Cc}\p{Cf}]/gu, '').trim();
  const count = typeof Intl !== 'undefined' && 'Segmenter' in Intl ? [...new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(flat)].length : [...flat].length;
  return flat && count <= limit ? flat : null;
}
const counted = (n: unknown) => Number.isSafeInteger(n) && (n as number) >= 0;

/** The table this browser understands, or null (another version, malformed, or too large). */
export function decodeProfileTable(raw: unknown): ProfileTable | null {
  try { if (new TextEncoder().encode(JSON.stringify(raw)).length > MAX_TABLE_BYTES) return null; } catch { return null; }
  const v = raw as Record<string, unknown>;
  if (!v || typeof v !== 'object' || Array.isArray(v) || v.version !== SUPPORTED_VERSION || !Array.isArray(v.profiles)) return null;
  if (!isProfileChoice(v.default)) return null;
  const options = <K extends string>(list: unknown, keys: readonly K[]): Partial<Record<K, Option>> => {
    const out: Partial<Record<K, Option>> = {};
    if (!Array.isArray(list)) return out;
    for (const item of list as Record<string, unknown>[]) {
      if (!item || typeof item !== 'object' || !keys.includes(item.id as K)) continue;
      const label = text(item.label, 24);
      if (!label) continue;
      out[item.id as K] = { label, detail: text(item.detail, 80) ?? '' };
    }
    return out;
  };
  const estimates = new Map<string, Estimate>();
  for (const p of (v.profiles as Record<string, unknown>[]).slice(0, 64)) {
    const choice = p && typeof p === 'object' ? { model: p.model, effort: p.effort, length: p.length } : null;
    const c = p?.credits as Record<string, unknown> | undefined;
    if (!isProfileChoice(choice) || !c || !counted(c.low) || !counted(c.high) || !counted(c.max)) continue;
    const e = { low: c.low as number, high: c.high as number, max: c.max as number };
    if (e.low > e.high || e.high > e.max || e.max >= 1_000_000) continue;
    estimates.set(profileID(choice), e);
  }
  const d = v.default as ProfileChoice, defaultChoice = { model: d.model, effort: d.effort, length: d.length };
  if (!estimates.has(profileID(defaultChoice))) return null;
  return { version: SUPPORTED_VERSION, defaultChoice, models: options(v.models, MODELS), efforts: options(v.efforts, EFFORTS),
    lengths: options(v.lengths, LENGTHS), estimates, note: text(v.estimate_note, 200) };
}

export const offers = (t: ProfileTable | null, c: ProfileChoice) => !!t?.estimates.has(profileID(c));
export const modelOption = (t: ProfileTable | null, m: ModelChoice) => t?.models[m] ?? BUILT_IN.models[m];
export const effortOption = (t: ProfileTable | null, e: EffortChoice) => t?.efforts[e] ?? BUILT_IN.efforts[e];
export const lengthOption = (t: ProfileTable | null, l: LengthChoice) => t?.lengths[l] ?? BUILT_IN.lengths[l];

const credits = (n: number) => n === 1 ? '1 credit' : `${n} credits`;
/** "Usually 4–24 credits · up to 37", "About 1 credit · up to 2". */
export function estimateText(e: Estimate): string {
  return `${e.low === e.high ? `About ${credits(e.low)}` : `Usually ${e.low}–${credits(e.high)}`} · up to ${e.max}`;
}
export function tableEstimate(t: ProfileTable | null, c: ProfileChoice): string | null {
  const e = t?.estimates.get(profileID(c));
  return e ? estimateText(e) : null;
}
/** The compact control's label: "Sonnet · Low · Standard". */
export function profileSummary(c: ProfileChoice, t: ProfileTable | null = null): string {
  return [modelOption(t, c.model).label, effortOption(t, c.effort).label, lengthOption(t, c.length).label].join(' · ');
}
export function apiModel(m: ModelChoice): string { return m === 'haiku' ? 'claude-haiku-5-5' : m === 'sonnet' ? 'claude-sonnet-5-5' : 'claude-opus-5-5'; }
/** "claude-sonnet-5" → "Claude Sonnet 5"; anything unexpected is shown bounded, as sent (ChatProfileText.modelName). */
export function modelName(id: string): string {
  const trimmed = [...id].slice(0, 64).join('');
  if (!trimmed.startsWith('claude-')) return trimmed;
  const words = trimmed.slice('claude-'.length).split('-').filter(Boolean);
  const family = words[0];
  if (!family) return trimmed;
  const version = words.slice(1).filter(w => w.length <= 2 && /^[0-9]+$/.test(w)).join('.');
  return `Claude ${family[0].toUpperCase()}${family.slice(1)}${version ? ` ${version}` : ''}`;
}
/** The line under an answer: "Sonnet · Low · Standard", plus "· by Claude Sonnet 5" when a fallback model wrote it. */
export function answeredBy(model: string | undefined, profile: string | undefined, t: ProfileTable | null = null): string | null {
  const choice = parseProfileID(profile);
  const parts: string[] = [];
  if (choice) parts.push(profileSummary(choice, t));
  if (model) {
    const expected = choice ? apiModel(choice.model) : null;
    if (model !== expected) parts.push(choice ? `by ${modelName(model)}` : modelName(model));
  }
  return parts.length ? parts.join(' · ') : null;
}

/** The published table, fetched once per login lifetime (a failure is retried on the next request). */
export class ProfileTableLoader {
  table: ProfileTable | null = null;
  private pending: Promise<ProfileTable | null> | null = null;
  constructor(private readonly account: string, private readonly signal: AbortSignal,
    private readonly fetchTable: (account: string, signal: AbortSignal) => Promise<unknown> = (account, signal) => functionGet('chat', { maximum: MAX_TABLE_BYTES, account, signal })) {}
  load(): Promise<ProfileTable | null> {
    if (this.table) return Promise.resolve(this.table);
    this.pending ??= this.fetchTable(this.account, this.signal).then(raw => (this.table = decodeProfileTable(raw)), () => null).finally(() => { this.pending = null; });
    return this.pending;
  }
}
