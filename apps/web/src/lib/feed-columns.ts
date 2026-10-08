// Presentation preferences contain only finite column IDs, never paper metadata or interest topics.
export const FEED_COLUMNS = [
  { key: 'popularity', label: 'Popularity', width: 122, detail: 'Upvotes on Hugging Face Papers' },
  { key: 'topic', label: 'Topics', width: 184, detail: 'Specific topics from the paper' },
  { key: 'published', label: 'Published', width: 102, detail: 'Month it appeared on arXiv' },
  { key: 'authors', label: 'Authors', width: 176, detail: 'The first authors' },
  { key: 'arxiv', label: 'arXiv ID', width: 120, detail: 'Its arXiv identifier' },
  { key: 'abstract', label: 'Abstract', width: 290, detail: 'A preview; expand the title for the full text' },
] as const;
export type FeedColumn = typeof FEED_COLUMNS[number]['key'];
export const FEED_COLUMNS_KEY = 'gradstep.feed.columns.v1';
export const defaultFeedColumns = (compact = false): FeedColumn[] => compact
  ? ['popularity', 'topic', 'published'] : ['popularity', 'topic', 'published', 'authors'];
export function parseFeedColumns(raw: string | null): FeedColumn[] | null {
  if (!raw || raw.length > 512) return null;
  try {
    const value = JSON.parse(raw);
    if (value?.version !== 1 || !Array.isArray(value.columns) || value.columns.length > FEED_COLUMNS.length
      || new Set(value.columns).size !== value.columns.length
      || !value.columns.every((c: unknown) => FEED_COLUMNS.some(column => column.key === c))) return null;
    return FEED_COLUMNS.filter(c => value.columns.includes(c.key)).map(c => c.key);
  } catch { return null; }
}
