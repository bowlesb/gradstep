// Study (experimental, 2026-10-14; docs/architecture/CHAT.md "Study"): an adaptive tutor for one paper. Every turn
// carries the reader's knowledge map (concepts with a state, links, the journey so far); the server's tutor adapts to
// it and sends the updated map back as a `study` event. The map lives in memory with the open chat: it is never
// written to this browser in the clear. This module is the browser port of supabase/functions/_shared/chat-study.ts.
export const STUDY_STATES = ['unknown', 'learning', 'known', 'verified'] as const;
export const STUDY_LINKS = ['prerequisite', 'deeper', 'related'] as const;
export const STUDY_NEXT = ['calibrate', 'teach', 'verify', 'deeper', 'tangent', 'revisit'] as const;
export type StudyState = typeof STUDY_STATES[number];
export interface StudyConcept { id: string; label: string; state: StudyState; paragraphs: number[]; note?: string }
export interface StudyLink { from: string; to: string; kind: typeof STUDY_LINKS[number] }
export interface StudyMap { concepts: StudyConcept[]; links: StudyLink[]; focus: string | null; journey: string[]; next: typeof STUDY_NEXT[number] }
export const STUDY_MAP_LIMITS = Object.freeze({ concepts: 60, links: 120, label: 80, note: 160, paragraphs: 8, journey: 80, bytes: 16_384 });
export const EMPTY_STUDY_MAP: StudyMap = Object.freeze({ concepts: [], links: [], focus: null, journey: [], next: 'calibrate' }) as StudyMap;

/** The reader's opening turn: the tutor starts with a calibrating question (on the selected passage when there is one). */
export function studyStart(selection: string | null = null): string {
  return selection ? `Start studying this paper, beginning with this passage: ${selection}` : 'Start studying this paper.';
}

const ID = /^[a-z0-9][a-z0-9_-]{0,39}$/;
const clean = (value: unknown, limit: number): string | null => {
  if (typeof value !== 'string') return null;
  const text = value.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/\s+/g, ' ').trim();
  return text && [...text].length <= limit ? text : null;
};
/** Validates a map from the server (untrusted). Null when unusable: a map is either whole or absent. */
export function studyMap(input: unknown): StudyMap | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const m = input as Record<string, unknown>;
  if (!Array.isArray(m.concepts) || !Array.isArray(m.links)) return null;
  if (m.concepts.length > STUDY_MAP_LIMITS.concepts || m.links.length > STUDY_MAP_LIMITS.links) return null;
  const concepts: StudyConcept[] = [], ids = new Set<string>();
  for (const raw of m.concepts) {
    if (!raw || typeof raw !== 'object') return null;
    const c = raw as Record<string, unknown>;
    const id = typeof c.id === 'string' && ID.test(c.id) ? c.id : null, label = clean(c.label, STUDY_MAP_LIMITS.label);
    if (!id || !label || ids.has(id) || !STUDY_STATES.includes(c.state as StudyState)) return null;
    const paragraphs = (Array.isArray(c.paragraphs) ? c.paragraphs : []).filter((n): n is number => Number.isSafeInteger(n) && n >= 1 && n <= 100_000);
    if (paragraphs.length > STUDY_MAP_LIMITS.paragraphs) return null;
    const note = c.note === undefined || c.note === null ? undefined : clean(c.note, STUDY_MAP_LIMITS.note) ?? undefined;
    ids.add(id); concepts.push({ id, label, state: c.state as StudyState, paragraphs: [...new Set(paragraphs)].sort((a, b) => a - b), ...(note ? { note } : {}) });
  }
  const links: StudyLink[] = [], seen = new Set<string>();
  for (const raw of m.links) {
    if (!raw || typeof raw !== 'object') return null;
    const l = raw as Record<string, unknown>;
    if (typeof l.from !== 'string' || typeof l.to !== 'string' || !ids.has(l.from) || !ids.has(l.to) || l.from === l.to || !STUDY_LINKS.includes(l.kind as StudyLink['kind'])) return null;
    const key = `${l.from}>${l.to}`; if (seen.has(key)) continue;
    seen.add(key); links.push({ from: l.from, to: l.to, kind: l.kind as StudyLink['kind'] });
  }
  const focus = typeof m.focus === 'string' && ids.has(m.focus) ? m.focus : null;
  if (!Array.isArray(m.journey) || m.journey.length > STUDY_MAP_LIMITS.journey || !m.journey.every((j): j is string => typeof j === 'string' && ids.has(j))) return null;
  const next = STUDY_NEXT.includes(m.next as StudyMap['next']) ? m.next as StudyMap['next'] : 'calibrate';
  const map: StudyMap = { concepts, links, focus, journey: m.journey, next };
  if (new TextEncoder().encode(JSON.stringify(map)).length > STUDY_MAP_LIMITS.bytes) return null;
  return map;
}

export const STATE_TEXT: Record<StudyState, string> = { unknown: 'Not yet', learning: 'Learning', known: 'Known', verified: 'Verified' };
export const NEXT_TEXT: Record<StudyMap['next'], string> = { calibrate: 'Finding your starting point', teach: 'Teaching', verify: 'Checking what you learned',
  deeper: 'Going deeper', tangent: 'Moving to a related idea', revisit: 'Returning to an earlier gap' };
export const LINK_TEXT: Record<StudyLink['kind'], string> = { prerequisite: 'builds on', deeper: 'goes deeper into', related: 'relates to' };

/** How many concepts are in each state. */
export function stateCounts(map: StudyMap): Record<StudyState, number> {
  const counts: Record<StudyState, number> = { unknown: 0, learning: 0, known: 0, verified: 0 };
  for (const c of map.concepts) counts[c.state]++;
  return counts;
}

// The map as a Mermaid flowchart, drawn by the same sandboxed frame as the agent's diagrams (strict mode, no network).
// Labels are quoted and stripped of the characters Mermaid reads as syntax; ids are prefixed so none is a keyword.
const node = (id: string) => `s_${id.replace(/[^a-z0-9_]/g, '_')}`;
const label = (text: string) => text.replace(/["\\[\]{}()<>|#;`]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 48) || 'concept';
const EDGE: Record<StudyLink['kind'], string> = { prerequisite: '-->', deeper: '-.->', related: '---' };
export function studyMermaid(map: StudyMap): string {
  const lines = ['flowchart TD'];
  for (const c of map.concepts) lines.push(`  ${node(c.id)}["${label(c.label)}"]:::${c.state}`);
  for (const l of map.links) lines.push(`  ${node(l.from)} ${EDGE[l.kind]} ${node(l.to)}`);
  lines.push('  classDef unknown fill:#fbe3e1,stroke:#c0392b,color:#1b1b1b',
    '  classDef learning fill:#fff1cc,stroke:#d68910,color:#1b1b1b',
    '  classDef known fill:#dbe9fb,stroke:#2e6fd0,color:#1b1b1b',
    '  classDef verified fill:#dcf3e2,stroke:#1f8f4e,color:#1b1b1b');
  if (map.focus) lines.push(`  style ${node(map.focus)} stroke-width:3px`);
  return lines.join('\n');
}
