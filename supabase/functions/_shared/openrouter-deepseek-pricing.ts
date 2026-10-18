// Reviewed DeepInfra FP8 revisions observed in OpenRouter's endpoints API, 2026-10-18. Peak prices bound off-peak bills.
export const ROUTER_DEEPSEEK_FLASH = 'deepseek/deepseek-v4.1-flash-1017';
export const ROUTER_DEEPSEEK_PRO = 'deepseek/deepseek-v4-pro-0813';
export const ROUTER_DEEPSEEK_TARIFF = 'openrouter-deepseek-deepinfra-20261018';
export const ROUTER_DEEPSEEK_ENDPOINT = 'deepinfra/fp8';
export const ROUTER_CONSENT_VERSION = 'cloud-ai-v6';
export const ROUTER_DEEPSEEK_EXPIRES = Date.parse('2027-01-01T00:00:00Z');
export const isRouterDeepSeek = (model: string) => model === ROUTER_DEEPSEEK_FLASH || model === ROUTER_DEEPSEEK_PRO;
export const routedDeepSeekModel = (model: string) => model === 'deepseek-flash' ? ROUTER_DEEPSEEK_FLASH : model === 'deepseek-v4-pro' ? ROUTER_DEEPSEEK_PRO : model;
export const clientDeepSeekModel = (model: string) => model === ROUTER_DEEPSEEK_FLASH ? 'deepseek-flash' : model === ROUTER_DEEPSEEK_PRO ? 'deepseek-v4-pro' : model;
export function routerDeepSeekRates(model: string) {
  if (!isRouterDeepSeek(model)) throw new Error('unsupported_model');
  const input = model === ROUTER_DEEPSEEK_FLASH ? 0.2 : 1.3;
  return { input, cacheWrite5m: input, cacheWrite1h: input, cacheRead: model === ROUTER_DEEPSEEK_FLASH ? 0.006 : 0.1,
    output: model === ROUTER_DEEPSEEK_FLASH ? 0.6 : 2.6 };
}
