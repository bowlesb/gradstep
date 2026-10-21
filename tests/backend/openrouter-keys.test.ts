import test from 'node:test';
import assert from 'node:assert/strict';
import { featureOf, routerKey } from '../../supabase/functions/_shared/openrouter-keys.ts';

test('A13: each feature uses its own OpenRouter key when provisioned, else the chat key', () => {
  const env = (values: Record<string, string>) => (name: string) => values[name];
  const all = env({ OPENROUTER_CHAT_API_KEY: 'chat', OPENROUTER_TAGS_API_KEY: 'tags', OPENROUTER_PODCAST_API_KEY: 'podcast' });
  assert.deepEqual([routerKey('chat', all), routerKey('tags', all), routerKey('podcast', all)], ['chat', 'tags', 'podcast']);
  const onlyChat = env({ OPENROUTER_CHAT_API_KEY: 'chat', OPENROUTER_TAGS_API_KEY: ' ' });
  assert.deepEqual([routerKey('tags', onlyChat), routerKey('podcast', onlyChat)], ['chat', 'chat'], 'until provisioned: the chat key, as before');
  assert.equal(routerKey('chat', env({})), null);
  // Generations are read with the key of the feature that created them (the attempt's recorded transport feature).
  assert.deepEqual(['catalog_tags', 'podcast_speech', 'podcast_script', 'chat', 'topic_title', null].map(featureOf),
    ['tags', 'podcast', 'podcast', 'chat', 'chat', 'chat']);
});
