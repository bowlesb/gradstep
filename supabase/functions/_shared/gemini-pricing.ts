// Selected after the 2026-10-16 comparison. This promotional card expires; it never silently rolls into a higher price.
export const GEMINI_MODEL = 'gemini-3.8-flash';
export const GEMINI_OPENROUTER_MODEL = `google/${GEMINI_MODEL}`;
export const GEMINI_ENDPOINT = 'google-ai-studio';
export const GEMINI_TARIFF = 'openrouter-google-flash-20261016';
export const GEMINI_PRICE_EXPIRES = Date.parse('2027-01-01T00:00:00Z');
// $/M tokens = micro-USD/token. A five-minute explicit cache costs up to 0.50 / 12 per million to store.
export const GEMINI_RATES = Object.freeze({ input: 0.75, output: 3.75, cacheRead: 0.075,
  cacheWrite5m: 0.75 + 0.50 / 12, cacheWrite1h: 0.75 + 0.50 / 12 });
