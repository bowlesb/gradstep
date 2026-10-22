// Download your assets in the browser: this browser's chats, diagrams, snippets (images decrypted here) and kept
// explanations, as lib/assets-export.ts takes them (the apps' AssetsExporter.swift gathers the same from the device).
// Nothing is sent: only a snippet image not yet in this browser is downloaded, encrypted, as Snippets downloads it.
import type { ChatSession } from './chat-session';
import type { EquationResult } from './equation';
import type { ConversationBranch } from './events';
import type { FigureResult } from './figure-view';
import type { KeptEntry } from './kept-explanations';
import type { MediaDescriptor } from './notes';
import type { PaperExplainerResult } from './paper-explainer';
import type { ExportCollection, ExportExplanation, ExportInput } from './assets-export';

/** `papers`: titles by the paper identity chats and explanations name (App's paperNames). */
export async function gatherExport(chat: ChatSession, papers: ReadonlyMap<string, string>, onProgress: (done: number, total: number) => void,
  signal?: AbortSignal): Promise<{ input: ExportInput; images: Map<string, Uint8Array> }> {
  const state = chat.history.state, skipped: string[] = [];

  // Chats: the version whose last message is newest (a chat continued on two devices has two).
  const latest = (b: ConversationBranch) => { const last = b.messages.at(-1); return last ? last.payload.createdAt ?? state.arrivalIndex(last.id) ?? -1 : -1; };
  const summaries = state.conversationSummaries();
  let unreadable = 0;
  const chats = summaries.flatMap(s => {
    const branches = state.conversationBranches(s.id);
    const branch = branches.reduce<ConversationBranch | null>((best, b) => (!best || latest(b) > latest(best) ? b : best), null);
    if (!branch) { if (s.messageCount > 0) unreadable++; return []; }
    const messages = branch.messages.flatMap(e => e.payload.role && e.payload.text !== undefined ? [{
      role: e.payload.role, text: e.payload.text, ...(e.payload.createdAt !== undefined ? { at: e.payload.createdAt } : {}),
      ...(e.payload.model ? { model: e.payload.model } : {}), ...(e.payload.status === 'interrupted' ? { interrupted: true } : {}),
    }] : []);
    const paper = s.documentID ? papers.get(s.documentID) : undefined;
    return [{ id: s.id, title: s.title, ...(paper ? { paper } : {}), ...(s.startedAt !== undefined ? { startedAt: s.startedAt } : {}),
      ...(s.anchor?.quote ? { passage: s.anchor.quote } : {}), ...(branches.length > 1 ? { versions: branches.length } : {}), messages }];
  });
  if (unreadable) skipped.push(`${unreadable} ${unreadable === 1 ? 'chat' : 'chats'} couldn’t be read in this browser yet.`);
  const chatTitles = new Map(summaries.map(s => [s.id, s.title]));

  const diagrams = state.savedDiagrams().map(d => ({ id: d.id, title: d.title, format: d.format, source: d.source,
    ...(d.createdAt !== undefined ? { at: d.createdAt } : {}), ...(d.conversationID && chatTitles.get(d.conversationID) ? { chat: chatTitles.get(d.conversationID)! } : {}) }));

  // Snippets, every collection, with their images decrypted here.
  const store = chat.noteStore, wanted: { id: string; media: MediaDescriptor }[] = [];
  const collections: ExportCollection[] = (store?.view().notes ?? []).filter(n => n.title !== null || n.entries.length).map(n => ({
    id: n.id, title: n.title ?? '',
    snippets: n.entries.map(e => {
      const r = e.record, src = r.source;
      if (r.media?.full) wanted.push({ id: r.entryID, media: r.media.full });
      return { id: r.entryID, kind: r.kind, at: r.capturedAt, comment: r.comment, ...(r.quote ? { quote: r.quote } : {}),
        ...(src ? { source: { title: src.title, ...(src.section ? { section: src.section } : {}), ...(src.label ? { label: src.label } : {}),
          ...(src.url ? { url: src.url } : {}), ...(src.page ? { page: src.page } : {}) } } : {}),
        ...(r.media?.full ? { image: r.media.full.type } : {}) };
    }),
  }));
  const images = new Map<string, Uint8Array>();
  onProgress(0, wanted.length);
  for (const [i, w] of wanted.entries()) {
    if (signal?.aborted) throw new DOMException('aborted', 'AbortError');
    try { if (store) images.set(w.id, await store.imageBytes(w.media)); } catch { /* said in the README */ }
    onProgress(i + 1, wanted.length);
  }

  return { input: { exportedAt: Date.now(), chats, diagrams, collections, explanations: keptExplanations(chat.keptEntries(), papers), skipped }, images };
}

/** Each explained equation, figure, part or paper once (the newest answer, whatever model), as Your assets lists them. A
 * part's or background's answer names its paper through the main answer of the same paper revision. */
export function keptExplanations(entries: readonly KeptEntry[], papers: ReadonlyMap<string, string>): ExportExplanation[] {
  const byManifest = new Map<string, string>(), labels = new Map<string, string>();
  for (const e of entries) if (e.listed) { byManifest.set(e.listed.manifest, e.listed.documentID); labels.set(`${e.listed.manifest}|${e.listed.targetID}`, e.listed.label); }
  const seen = new Set<string>(), out: ExportExplanation[] = [];
  for (const e of [...entries].sort((a, b) => b.savedAt - a.savedAt)) {
    const parts = e.key.split('|'), manifest = parts[0] ?? '';
    const target = e.kind === 'paper' ? 'paper' : parts[1] ?? '', action = e.kind === 'paper' ? 'paper_explainer' : parts[2] ?? '';
    if (action === 'figure_detail') continue; // an older page's "Extract the subfigure" answers are never shown
    if (seen.has(`${manifest}|${target}|${action}|${e.kind === 'figure' ? parts[4] ?? '' : ''}`)) continue;
    seen.add(`${manifest}|${target}|${action}|${e.kind === 'figure' ? parts[4] ?? '' : ''}`);
    const documentID = e.listed?.documentID ?? byManifest.get(manifest);
    const paper = (documentID && papers.get(documentID)) || '';
    const label = e.listed?.label ?? labels.get(`${manifest}|${target}`) ?? (e.kind === 'equation' ? 'Equation' : e.kind === 'figure' ? 'Figure' : 'AI Explainer');
    const base = { action, paper, label, at: e.savedAt };
    if (e.kind === 'equation') {
      const r = e.result as EquationResult;
      out.push({ kind: 'equation', ...base, ...(r.model ? { model: r.model } : {}), ...(r.symbols ? { summary: r.symbols.summary, symbols: r.symbols.symbols } : {}), text: r.text ?? '' });
    } else if (e.kind === 'figure') {
      const r = e.result as FigureResult;
      out.push({ kind: 'figure', ...base, ...(r.model ? { model: r.model } : {}),
        ...(r.walkthrough ? { summary: r.walkthrough.summary, sections: r.walkthrough.sections.map(s => ({ name: s.label || s.title, title: s.title, text: s.text, paragraphs: s.paragraphs })) } : {}),
        text: r.text ?? '' });
    } else {
      const r = e.result as PaperExplainerResult, x = r.explainer;
      const names = new Map([...(x?.background ?? []), ...(x?.ideas ?? [])].map(i => [i.id, i.name]));
      const items = (list: { name: string; line: string; paragraphs: number[] }[]) => list.map(i => ({ name: i.name, line: i.line, paragraphs: i.paragraphs }));
      out.push({ kind: 'paper', ...base, label: 'AI Explainer', ...(r.model ? { model: r.model } : {}),
        ...(x ? { summary: x.summary, background: items(x.background), ideas: items(x.ideas),
          links: x.links.map(l => ({ from: names.get(l.from) ?? l.from, to: names.get(l.to) ?? l.to, label: l.label })) } : {}),
        text: r.text ?? '' });
    }
  }
  return out;
}
