// OpenRouter keys per feature (review A13; PROVIDER_SPENDING.md "Per-feature keys"). One key for chat, tags and podcasts
// let a runaway podcast or tag job drain the balance every chat needs. Each feature may have its own key with
// OpenRouter's own per-key credit limit; until the owner provisions them (a recorded infrastructure step), every feature
// falls back to the chat key, as before. Keys are read from the environment only and never logged.
export type RouterFeature = 'chat' | 'tags' | 'podcast';
const NAMES: Readonly<Record<RouterFeature, string>> = { chat: 'OPENROUTER_CHAT_API_KEY', tags: 'OPENROUTER_TAGS_API_KEY', podcast: 'OPENROUTER_PODCAST_API_KEY' };

export function routerKey(feature: RouterFeature, env: (name: string) => string | undefined): string | null {
  return env(NAMES[feature])?.trim() || env(NAMES.chat)?.trim() || null;
}

/** The feature an admitted attempt was dispatched for (its recorded transport `feature`), for reading its generation. */
export function featureOf(transportFeature: string | null): RouterFeature {
  if (transportFeature === 'catalog_tags') return 'tags';
  if (transportFeature?.startsWith('podcast')) return 'podcast';
  return 'chat';
}
