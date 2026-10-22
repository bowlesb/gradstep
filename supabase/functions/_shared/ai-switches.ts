// The owner's AI switches (migration 0150, `worker_ai_switches`; docs/RUNBOOK_SPENDING.md). The database refuses
// switched-off work on its own (`platform_budget_exhausted`); the chat function reads the switches first so a reader gets
// the clearer answer before anything is held, and publishes cheaper defaults while "cheaper models only" is on.
import type { ChatAction, ChatErrorCode } from './chat.ts';

/** As `worker_ai_switches` returns them; the patterns are the owner's own configuration (model families). */
export interface AiSwitches { cheap_models_only: boolean; paused_features: string[]; premium_models: string; free_models: string }

const FEATURE_SWITCH: Partial<Record<ChatAction, string>> = { figure: 'figures', figure_simpler: 'figures', figure_detail: 'figures',
  equation: 'equations', equation_background: 'equations' };
const matches = (pattern: string | undefined, model: string) => { try { return !!pattern && new RegExp(pattern, 'i').test(model); } catch { return false; } };

/** What a switch refuses for this request, before anything is held: a paused feature reads as paused; a premium model
 * while "cheaper models only" is on reads as unavailable (the reader picks another). Null: the request may go ahead. */
export function switchRefusal(switches: AiSwitches | null, action: ChatAction | null, apiModel: string): ChatErrorCode | null {
  if (!switches) return null;
  const feature = action ? FEATURE_SWITCH[action] : undefined;
  if (feature && Array.isArray(switches.paused_features) && switches.paused_features.includes(feature)) return 'platform_budget_exhausted';
  if (switches.cheap_models_only === true && matches(switches.premium_models, apiModel)) return 'model_unavailable';
  return null;
}

/** A fast model free credits may pay for. The database decides; this only keeps web search off free answers. */
export const freeModel = (switches: AiSwitches | null, apiModel: string) => !!switches && matches(switches.free_models, apiModel)
  && !matches(switches.premium_models, apiModel);

const CHEAP = Object.freeze({ model: 'gemini', length: 'standard' });
/** The published profile table with every default on Gemini Flash (when it is published at all; otherwise unchanged). */
export function withCheapDefaults<T extends { models: { id: string }[] }>(table: T): T {
  if (!table.models.some(m => m.id === CHEAP.model)) return table;
  const fixed = { ...CHEAP, effort: 'medium' };
  return { ...table, default: { ...fixed }, default_recommended: { ...fixed }, default_figures: { ...fixed },
    default_auto: { ...CHEAP, effort: 'auto' } };
}
