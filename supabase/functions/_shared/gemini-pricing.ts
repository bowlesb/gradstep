// Selected after the 2026-10-16 comparison. The card's validity is app_private.openrouter_tariffs (migration 0101), read by
// admission and the chat function; it never silently rolls into a higher price (each request also caps the price).
export const GEMINI_MODEL = 'gemini-3.8-flash';
export const GEMINI_OPENROUTER_MODEL = `google/${GEMINI_MODEL}`;
export const GEMINI_ENDPOINT = 'google-vertex/us';
export const GEMINI_TARIFF = 'openrouter-google-flash-vertex-us-20261017';
// $/M tokens = micro-USD/token. A five-minute explicit cache costs up to 0.50 / 12 per million to store.
export const GEMINI_RATES = Object.freeze({ input: 0.825, output: 4.125, cacheRead: 0.0825,
  cacheWrite5m: 0.825 + 0.50 / 12, cacheWrite1h: 0.825 + 0.50 / 12 });
