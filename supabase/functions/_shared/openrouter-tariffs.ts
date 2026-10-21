// OpenRouter price-card validity (review A4, migration 0101; PROVIDER_SPENDING.md "Tariff validity"). The table is the
// authority: admission refuses a model whose card has lapsed. The chat function reads the same table (through
// worker_provider_spending_policy) so it stops offering a model a day before its card lapses and stops accepting it
// shortly before, instead of placing holds that admission then refuses.

/** The profile table stops listing a model this long before its card lapses (clients cache the table). */
export const PUBLISH_MARGIN_MS = 24 * 3600_000;
/** A request is refused as `model_unavailable` when its model's card lapses within this (longer than any answer). */
export const ACCEPT_MARGIN_MS = 10 * 60_000;

/** `{model: valid_until}` from the policy read, or null when it could not be read (admission still decides). */
export type TariffValidity = Readonly<Record<string, string>> | null;

export function tariffValidity(policy: unknown): TariffValidity {
  const value = policy && typeof policy === 'object' ? (policy as { openrouter_tariffs?: unknown }).openrouter_tariffs : undefined;
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const out: Record<string, string> = {};
  for (const [model, until] of Object.entries(value as Record<string, unknown>)) if (typeof until === 'string') out[model] = until;
  return out;
}

/** Whether `model`'s card is still valid `marginMs` from now. Unknown validity (null) is open: admission decides. A
 * model the table does not name has no valid card. */
export function tariffOpen(validity: TariffValidity, model: string, marginMs: number, now = Date.now()): boolean {
  if (!validity) return true;
  const until = Date.parse(validity[model] ?? '');
  return Number.isFinite(until) && until - now > marginMs;
}
