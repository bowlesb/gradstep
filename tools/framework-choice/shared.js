export const ROW_HEIGHT = 52, VIEW_HEIGHT = 520, OVERSCAN = 8;
const cache = new Map();
const topics = ['Diffusion', 'Transformers', 'Reinforcement learning', 'Vision', 'Optimization', 'Language'];
export function prepare(count) {
  if (!cache.has(count)) cache.set(count, Array.from({length: count}, (_, i) => ({
    id: i + 1,
    title: topics[i % topics.length] + ' methods for ' + ['robust','efficient','scalable','interpretable'][i % 4] + ' machine learning ' + String(count - i).padStart(6, '0'),
    author: 'Researcher ' + i % 251,
    year: 1995 + i % 32,
    tag: topics[i % topics.length],
    progress: i % 101,
    search: (topics[i % topics.length] + ' researcher ' + i % 251).toLowerCase()
  })));
}
export function papers(count) { return cache.get(count); }
export function filterSort(rows, query, descending) {
  const q = query.trim().toLowerCase();
  const filtered = q ? rows.filter(row => row.search.includes(q)) : rows;
  return descending ? filtered.toSorted((a, b) => b.title.localeCompare(a.title)) : filtered;
}
export function windowRange(length, scrollTop, virtual) {
  if (!virtual) return {start:0, end:length, before:0, after:0};
  const start = Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - OVERSCAN);
  const end = Math.min(length, start + Math.ceil(VIEW_HEIGHT / ROW_HEIGHT) + OVERSCAN * 2);
  return {start, end, before:start * ROW_HEIGHT, after:Math.max(0,length-end) * ROW_HEIGHT};
}
export function changed(rows) {
  return rows.map((row, i) => i % 10 === 0 ? {...row, progress:(row.progress + 1) % 101} : row);
}
export const nextPaint = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
