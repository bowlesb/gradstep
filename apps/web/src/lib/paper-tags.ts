import type { ClientEntry } from './device-pdf';
// Matches ScienceReaderCore/PaperTags.swift and migration 030. Catalog tags are shared metadata;
// the reader's additions and hidden catalog tags are revision-checked library fields, not chat events.
import { TAG_VOCABULARY, tagsFromCategories } from '../../../../supabase/functions/_shared/tag-vocabulary.ts';
import type { Entry } from './library';

export const MAX_OWN_TAGS = 12, MAX_HIDDEN_TAGS = 8;
export const MAX_TAG_SCALARS = 40, MAX_TAG_BYTES = 120;
export const containsTag = (tags: readonly string[], value: string) => tags.some(tag => tag.toLowerCase() === value.toLowerCase());
export function normalizeTag(raw: string): string | null {
  // Swift strings contain Unicode scalars; JS can also contain lone UTF-16 surrogates, which
  // JSON/Postgres cannot round-trip. Do not silently replace those with a different tag.
  if (/\p{Cs}/u.test(raw)) return null;
  const text = raw.replace(/[\s\p{Cc}\p{Cf}]+/gu, ' ').trim();
  return text && [...text].length <= MAX_TAG_SCALARS && new TextEncoder().encode(text).length <= MAX_TAG_BYTES ? text : null;
}
export const validTags = (tags: readonly string[], limit: number) => tags.length <= limit
  && tags.every(tag => normalizeTag(tag) === tag) && new Set(tags.map(tag => tag.toLowerCase())).size === tags.length;
export function editedTags(catalog: readonly string[], desired: readonly string[]) {
  const chosen: string[] = [];
  for (const raw of desired) {
    const value = normalizeTag(raw);
    if (!value) throw new Error('invalid_tags');
    if (!containsTag(chosen, value)) chosen.push(value);
  }
  const own = chosen.filter(tag => !containsTag(catalog, tag));
  const hidden = catalog.filter((tag, i) => !containsTag(chosen, tag) && !containsTag(catalog.slice(0, i), tag));
  if (!validTags(own, MAX_OWN_TAGS) || !validTags(hidden, MAX_HIDDEN_TAGS)) throw new Error('invalid_tags');
  return { own, hidden };
}

/** Other visible papers' own tags, most-used first (native ownTagsInLibrary). */
export function ownTagsInLibrary(entries: readonly ClientEntry[], excluding: string): string[] {
  const counts = new Map<string, { name: string; count: number }>();
  for (const item of entries) if (item.visible && item.id !== excluding) {
    const seen = new Set<string>();
    for (const tag of item.user_tags ?? []) {
      const key = tag.toLowerCase();
      if (seen.has(key) || normalizeTag(tag) !== tag) continue;
      seen.add(key);
      const old = counts.get(key);
      counts.set(key, { name: old?.name ?? tag, count: (old?.count ?? 0) + 1 });
    }
  }
  return [...counts.values()].sort((a, b) => b.count - a.count || a.name.localeCompare(b.name)).map(t => t.name);
}

/** Same prefix/word/substring ranking and eight-result cap as TagEditorView/TagVocabulary. */
export function tagSuggestions(catalog: readonly string[], categories: readonly string[], chosen: readonly string[], own: readonly string[], query: string) {
  const result: { name: string; detail?: string }[] = [];
  const add = (name: string, detail?: string) => {
    if (!containsTag(chosen, name) && !result.some(t => t.name.toLowerCase() === name.toLowerCase()) && normalizeTag(name) === name) result.push({ name, detail });
  };
  const text = normalizeTag(query)?.toLowerCase();
  if (text) {
    const rank = (name: string) => name.startsWith(text) ? 0 : name.split(' ').some(word => word.startsWith(text)) || name.includes('-' + text) ? 1 : name.includes(text) ? 2 : 3;
    for (const tag of TAG_VOCABULARY.filter(t => !containsTag(chosen, t.name) && rank(t.name.toLowerCase()) < 3)
      .sort((a, b) => rank(a.name.toLowerCase()) - rank(b.name.toLowerCase()) || a.name.localeCompare(b.name)).slice(0, 6)) add(tag.name, tag.definition);
    for (const tag of own) if (tag.toLowerCase().includes(text)) add(tag, 'Your tag');
  } else {
    for (const name of [...catalog, ...tagsFromCategories(categories)]) add(name, TAG_VOCABULARY.find(t => t.name.toLowerCase() === name.toLowerCase())?.definition);
    for (const tag of own.slice(0, 6)) add(tag, 'Your tag');
  }
  return result.slice(0, 8);
}
