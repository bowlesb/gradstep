// Settings' AI defaults by activity (owner, 2026-10-21): Podcasts' default writer (only writers the server lists, the
// default preselected when the chosen length offers it) and the explainer, word for word the same in the apps.
import { readFileSync } from 'node:fs';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AI_DEFAULTS_GUIDE, aiDefaultsGuide } from '../src/lib/chat-session';
import { chooseWriter, decodeCapabilities, offeredWriters, savePodcastWriter, savedPodcastWriter } from '../src/lib/podcast';

const writer = (id: string, label: string, max = 150) => ({ writer: id, label, max_credits: max });
const capabilities = decodeCapabilities({ catalog: true, generation: true, delivery: true, lengths: [
  { profile: 'podcast-short-v1', label: 'Short', target_seconds: 150, max_credits: 60, writers: [writer('deepseek', 'DeepSeek V4 Pro', 60)] },
  { profile: 'podcast-5min-v1', label: '5 min', target_seconds: 300, max_credits: 150, writers: [writer('deepseek', 'DeepSeek V4 Pro'), writer('anthropic', 'Claude Sonnet 5.5', 200)] },
] });

describe('the podcast writer default', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('offers every writer the server lists for any length, once each, the default first', () => {
    expect(offeredWriters(capabilities).map(w => w.label)).toEqual(['DeepSeek V4 Pro', 'Claude Sonnet 5.5']);
    expect(offeredWriters(decodeCapabilities({ catalog: true, generation: true }))).toEqual([]);
  });

  it('preselects the default only where the length offers it, after a choice made in the sheet', () => {
    const [short, five] = capabilities.lengths!;
    expect(chooseWriter(five.writers, null, 'anthropic')).toBe('anthropic');
    expect(chooseWriter(short.writers, null, 'anthropic')).toBe('deepseek'); // not offered for Short: the server's default
    expect(chooseWriter(five.writers, 'deepseek', 'anthropic')).toBe('deepseek'); // the sheet's own choice wins
    expect(chooseWriter(five.writers, null, null)).toBe('deepseek');
    expect(chooseWriter([], null, 'anthropic')).toBeNull(); // no writers listed: the server decides
  });

  it('is kept in this browser, and forgetting it follows the server again', () => {
    const stored = new Map<string, string>();
    vi.stubGlobal('localStorage', { getItem: (k: string) => stored.get(k) ?? null, setItem: (k: string, v: string) => { stored.set(k, v); }, removeItem: (k: string) => { stored.delete(k); } });
    expect(savedPodcastWriter()).toBeNull();
    savePodcastWriter('anthropic'); expect(savedPodcastWriter()).toBe('anthropic');
    savePodcastWriter(null); expect(savedPodcastWriter()).toBeNull();
    stored.set('gradstep.ai.podcastWriter.v1', 'Not a writer!'); expect(savedPodcastWriter()).toBeNull();
    vi.stubGlobal('localStorage', { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); }, removeItem: () => { throw new Error('blocked'); } });
    expect(savedPodcastWriter()).toBeNull(); expect(() => savePodcastWriter('deepseek')).not.toThrow();
  });
});

describe('the AI defaults explainer', () => {
  it('says what each activity does, then cost, speed and quality, and when to change', () => {
    for (const activity of ['general', 'paper', 'equations', 'figures', 'podcasts'] as const) {
      const text = aiDefaultsGuide(activity);
      expect(text.startsWith(AI_DEFAULTS_GUIDE[activity])).toBe(true);
      expect(text).toContain(AI_DEFAULTS_GUIDE.overview); expect(text).toContain(AI_DEFAULTS_GUIDE.whenToChange);
    }
  });

  it('is word for word the apps’ text', () => {
    const swift = readFileSync(new URL('../../apple/ScienceReader/Views/AIScenarioDefaults.swift', import.meta.url), 'utf8');
    for (const [key, text] of Object.entries(AI_DEFAULTS_GUIDE)) expect(swift, key).toContain(`static let ${key} = "${text}"`);
  });
});
