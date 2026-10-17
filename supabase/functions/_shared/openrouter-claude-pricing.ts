// Reviewed OpenRouter Google Vertex US endpoint rates, 2026-10-17. Independent of direct Anthropic's rate card.
export const ROUTER_CLAUDE_ENDPOINT = 'google-vertex/us';
export const ROUTER_CLAUDE_TARIFF = 'openrouter-claude-vertex-us-20261017';
export const ROUTER_CLAUDE_PRICE_EXPIRES = Date.parse('2027-01-01T00:00:00Z');
const MODELS: Readonly<Record<string, string>> = Object.freeze({
  'claude-haiku-5-5': 'anthropic/claude-haiku-5.5',
  'claude-sonnet-5-5': 'anthropic/claude-sonnet-5.5',
  'claude-opus-5-5': 'anthropic/claude-opus-5.5',
});
export function routedClaudeModel(model: string): string { return MODELS[model] ?? model; }
export function clientClaudeModel(model: string): string { return Object.entries(MODELS).find(([, routed]) => routed === model)?.[0] ?? model; }
export function isRouterClaude(model: string): boolean { return Object.values(MODELS).includes(model); }
export function routerClaudeRates(model: string, promptTokens = 0) {
  if (!isRouterClaude(model)) throw new Error('unsupported_model');
  const haiku = model === MODELS['claude-haiku-5-5'];
  const input = haiku ? (promptTokens > 100_000 ? 0.55 : 0.11) : model === MODELS['claude-sonnet-5-5'] ? 2.2 : 4.4;
  return { input, output: input * 5, cacheWrite5m: input * 1.25, cacheWrite1h: input * 2, cacheRead: input * (haiku ? 0.1 : 0.05) };
}
