// A chat's model, effort and length (owner request 2026-10-08) — a port of ScienceReaderCore/ChatProfiles.swift.
// The chat function accepts only its published, versioned table (`GET functions/v1/chat`, chat-profiles-v1) and holds
// and charges at the chosen model's rates; this browser only sends the choice and displays the server's estimates.
// Contract: docs/architecture/CHAT.md#models-effort-and-length. Since the build 57 redesign (CHAT.md, 2026-10-16) the
// reader chooses only the model and the length; where the server publishes `auto` profiles, requests send
// `effort: "auto"` and the server picks the effort per question.
import { functionGet } from './backend';

export type ModelChoice = 'haiku' | 'sonnet' | 'opus' | 'deepseek';
export type EffortChoice = 'low' | 'medium' | 'high';
export type LengthChoice = 'brief' | 'standard' | 'detailed';
/** A stored choice (a chat's, this browser's default, a saved question's): always a concrete effort, so journals and
 * older tabs read it unchanged. What a request sends is `requestProfile` (effort `auto` where the server offers it). */
export interface ProfileChoice { model: ModelChoice; effort: EffortChoice; length: LengthChoice }
/** Automatic effort (2026-10-16): the server picks low, medium or high per question before it holds credits. */
export type RequestEffort = EffortChoice | 'auto';
export interface RequestProfile { model: ModelChoice; effort: RequestEffort; length: LengthChoice }

export const MODELS: readonly ModelChoice[] = ['haiku', 'sonnet', 'opus', 'deepseek'];
export const EFFORTS: readonly EffortChoice[] = ['low', 'medium', 'high'];
const REQUEST_EFFORTS: readonly RequestEffort[] = [...EFFORTS, 'auto'];
export const LENGTHS: readonly LengthChoice[] = ['brief', 'standard', 'detailed'];
/** Today's answers (and every request without a choice): Sonnet, low effort, standard length. */
export const STANDARD_PROFILE: Readonly<ProfileChoice> = Object.freeze({ model: 'sonnet', effort: 'low', length: 'standard' });

export const profileID = (c: ProfileChoice | RequestProfile) => `${c.model}-${c.effort}-${c.length}`;
export const sameProfile = (a: ProfileChoice, b: ProfileChoice) => a.model === b.model && a.effort === b.effort && a.length === b.length;
/** What the reader sees and chooses: the model and the length. */
export const sameChoice = (a: ProfileChoice, b: ProfileChoice) => a.model === b.model && a.length === b.length;
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
const isRequestProfile = (v: unknown): v is RequestProfile => !!v && typeof v === 'object' && !Array.isArray(v)
  && MODELS.includes((v as RequestProfile).model) && REQUEST_EFFORTS.includes((v as RequestProfile).effort) && LENGTHS.includes((v as RequestProfile).length);

export interface Option { label: string; detail: string; apiModel?: string; provider?: string }
const BUILT_IN: { models: Record<ModelChoice, Option>; efforts: Record<RequestEffort, Option>; lengths: Record<LengthChoice, Option> } = {
  models: { haiku: { label: 'Haiku', detail: 'Fastest and cheapest', apiModel: 'claude-haiku-5-5' },
    sonnet: { label: 'Sonnet', detail: 'Strong answers at a moderate cost', apiModel: 'claude-sonnet-5-5' },
    opus: { label: 'Opus', detail: 'Most capable; costs the most', apiModel: 'claude-opus-5-5' },
    deepseek: { label: 'DeepSeek', detail: 'Lower cost; reads text and figures', apiModel: 'deepseek-flash' } },
  efforts: { low: { label: 'Low', detail: 'Thinks only when needed; quickest' }, medium: { label: 'Medium', detail: 'Thinks through harder questions' },
    high: { label: 'High', detail: 'Thinks carefully; slowest' }, auto: { label: 'Automatic', detail: 'Chosen for each question' } },
  lengths: { brief: { label: 'Brief', detail: 'A few sentences' }, standard: { label: 'Standard', detail: 'Focused answers' },
    detailed: { label: 'Detailed', detail: 'Thorough, with derivations and caveats' } },
};
/** Settings › AI chat options: what each model is good at (the table's one-line detail stays the headline). */
export const MODEL_STRENGTHS: Record<ModelChoice, string> = {
  haiku: 'Quick definitions, lookups and short explanations.',
  sonnet: 'Most questions about a paper: the method, the results, a derivation.',
  opus: 'The hardest questions: long derivations, careful critique, comparing approaches.',
  deepseek: 'A lower-cost alternative for questions about the text and its figures.',
};

export interface Estimate { low: number; high: number; max: number }
/** The server's published table, decoded tolerantly and bounded (ChatProfileTable.decode). */
export interface ProfileTable {
  version: string; defaultChoice: ProfileChoice;
  models: Partial<Record<ModelChoice, Option>>; efforts: Partial<Record<RequestEffort, Option>>; lengths: Partial<Record<LengthChoice, Option>>;
  /** Offered profiles by identifier, automatic ones included (`sonnet-auto-standard`). A choice the server doesn't list isn't offered. */
  estimates: Map<string, Estimate>; note: string | null;
  /** The server's automatic default (`default_auto`, 2026-10-16), when it publishes one it offers. */
  autoDefault: RequestProfile | null;
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

/** The table this browser understands, or null (another version, malformed, or too large). Servers from 2026-10-16 add,
 * within the same version, `auto` profiles (and an `auto` effort), `default_auto` and a `deepseek` model; a table
 * without them decodes exactly as before. */
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
      const apiModel = text(item.api_model, 64), provider = text(item.provider, 40);
      out[item.id as K] = { label, detail: text(item.detail, 80) ?? '', ...(apiModel ? { apiModel } : {}), ...(provider ? { provider } : {}) };
    }
    return out;
  };
  const estimates = new Map<string, Estimate>();
  for (const p of (v.profiles as Record<string, unknown>[]).slice(0, 128)) {
    const choice = p && typeof p === 'object' ? { model: p.model, effort: p.effort, length: p.length } : null;
    const c = p?.credits as Record<string, unknown> | undefined;
    if (!isRequestProfile(choice) || !c || !counted(c.low) || !counted(c.high) || !counted(c.max)) continue;
    const e = { low: c.low as number, high: c.high as number, max: c.max as number };
    if (e.low > e.high || e.high > e.max || e.max >= 1_000_000) continue;
    estimates.set(profileID(choice), e);
  }
  const d = v.default as ProfileChoice, defaultChoice = { model: d.model, effort: d.effort, length: d.length };
  if (!estimates.has(profileID(defaultChoice))) return null;
  const a = v.default_auto;
  const autoDefault = isRequestProfile(a) && a.effort === 'auto' && estimates.has(profileID(a)) ? { model: a.model, effort: a.effort, length: a.length } : null;
  return { version: SUPPORTED_VERSION, defaultChoice, models: options(v.models, MODELS), efforts: options(v.efforts, REQUEST_EFFORTS),
    lengths: options(v.lengths, LENGTHS), estimates, note: text(v.estimate_note, 200), autoDefault };
}

export const offers = (t: ProfileTable | null, c: ProfileChoice | RequestProfile) => !!t?.estimates.has(profileID(c));
/** Whether the server picks the effort for this model and length (an `auto` profile is published for it). */
export const offersAuto = (t: ProfileTable | null, model: ModelChoice, length: LengthChoice) => offers(t, { model, effort: 'auto', length });
/** Whether the table offers automatic effort at all. */
export const hasAutoEffort = (t: ProfileTable | null) => !!t && [...t.estimates.keys()].some(id => id.split('-')[1] === 'auto');
/** What a request for this choice sends: effort `auto` where the server offers it, else the stored effort; null when
 * the table offers neither. */
export function requestProfile(t: ProfileTable | null, c: ProfileChoice): RequestProfile | null {
  if (offersAuto(t, c.model, c.length)) return { model: c.model, effort: 'auto', length: c.length };
  return offers(t, c) ? { model: c.model, effort: c.effort, length: c.length } : null;
}
/** A choice this table can answer (with automatic or the stored effort). */
export const available = (t: ProfileTable | null, c: ProfileChoice) => requestProfile(t, c) !== null;
/** The models to show: Haiku, Sonnet and Opus always; DeepSeek only when the server's table lists it. */
export const listedModels = (t: ProfileTable | null): ModelChoice[] => MODELS.filter(m => m !== 'deepseek' || !!t?.models.deepseek);
/** Whether a model and length can be answered at all (automatically or at some effort). */
export const offersModelLength = (t: ProfileTable | null, model: ModelChoice, length: LengthChoice) =>
  offersAuto(t, model, length) || EFFORTS.some(effort => offers(t, { model, effort, length }));
/** The choice with another model or length: keeps the stored effort where it is offered, else low, else any offered. */
export function withChoice(t: ProfileTable | null, c: ProfileChoice, change: { model?: ModelChoice; length?: LengthChoice }): ProfileChoice {
  const model = change.model ?? c.model, length = change.length ?? c.length;
  const effort = [c.effort, 'low' as const, ...EFFORTS].find(e => offers(t, { model, effort: e, length })) ?? c.effort;
  return { model, effort, length };
}
export const modelOption = (t: ProfileTable | null, m: ModelChoice): Option => ({ ...BUILT_IN.models[m], ...t?.models[m] });
export const effortOption = (t: ProfileTable | null, e: RequestEffort) => t?.efforts[e] ?? BUILT_IN.efforts[e];
export const lengthOption = (t: ProfileTable | null, l: LengthChoice) => t?.lengths[l] ?? BUILT_IN.lengths[l];
/** Who processes a request with this model: Anthropic for Claude, DeepSeek for DeepSeek (or what the table says). */
export const modelProvider = (t: ProfileTable | null, m: ModelChoice) => modelOption(t, m).provider ?? (m === 'deepseek' ? 'DeepSeek' : 'Anthropic');

const credits = (n: number) => n === 1 ? '1 credit' : `${n} credits`;
/** "Usually 4–24 credits · up to 37", "About 1 credit · up to 2". */
export function estimateText(e: Estimate): string {
  return `${e.low === e.high ? `About ${credits(e.low)}` : `Usually ${e.low}–${credits(e.high)}`} · up to ${e.max}`;
}
export function tableEstimate(t: ProfileTable | null, c: ProfileChoice | RequestProfile): string | null {
  const e = t?.estimates.get(profileID(c));
  return e ? estimateText(e) : null;
}
/** The credit table's cell for a model and length: the automatic profile's estimate where published, else low effort's. */
export function typicalEstimate(t: ProfileTable | null, model: ModelChoice, length: LengthChoice): Estimate | null {
  return t?.estimates.get(`${model}-auto-${length}`) ?? t?.estimates.get(`${model}-low-${length}`) ?? null;
}
/** The choice as the reader sees it, everywhere: "Sonnet · Standard" (owner, build 57: effort is chosen automatically). */
export function profileSummary(c: { model: ModelChoice; length: LengthChoice }, t: ProfileTable | null = null): string {
  return [modelOption(t, c.model).label, lengthOption(t, c.length).label].join(' · ');
}
export function apiModel(m: ModelChoice, t: ProfileTable | null = null): string { return modelOption(t, m).apiModel ?? BUILT_IN.models[m].apiModel!; }
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
/** The line under an answer: "Sonnet · Standard", plus "· by Claude Sonnet 5" when a fallback model wrote it. */
export function answeredBy(model: string | undefined, profile: string | undefined, t: ProfileTable | null = null): string | null {
  const choice = parseProfileID(profile);
  const parts: string[] = [];
  if (choice) parts.push(profileSummary(choice, t));
  if (model) {
    const expected = choice ? apiModel(choice.model, t) : null;
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
