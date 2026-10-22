import { useEffect, useRef, useState } from 'react';
import { buildExport, zip } from '../lib/assets-export';
import { gatherExport } from '../lib/assets-export-gather';
import type { ChatSession } from '../lib/chat-session';
import { Dialog } from './common';

type Phase = { kind: 'idle' } | { kind: 'preparing'; done: number; total: number } | { kind: 'done'; fileName: string; skipped: string[] } | { kind: 'failed' };

/** Save a file this page made (Catalogs' CSV does the same); nothing is sent. */
function save(fileName: string, bytes: Uint8Array) {
  const url = URL.createObjectURL(new Blob([bytes as Uint8Array<ArrayBuffer>], { type: 'application/zip' })), link = document.createElement('a');
  link.href = url; link.download = fileName; link.hidden = true;
  document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

/** Your assets › Download your assets (owner, build 82: "Need a download assets button"; the apps' AssetsExportRow): this
 * browser's own content as one .zip made here (lib/assets-export.ts), then saved as any download. */
export function AssetsExportDialog({ chat, papers, open, onClose }: { chat: ChatSession; papers: ReadonlyMap<string, string>; open: boolean; onClose: () => void }) {
  const [phase, setPhase] = useState<Phase>({ kind: 'idle' });
  const controller = useRef<AbortController | null>(null);
  useEffect(() => { if (!open) { controller.current?.abort(); setPhase({ kind: 'idle' }); } }, [open]);
  useEffect(() => () => controller.current?.abort(), []);

  const run = async () => {
    controller.current?.abort();
    const c = new AbortController(); controller.current = c;
    setPhase({ kind: 'preparing', done: 0, total: 0 });
    try {
      const { input, images } = await gatherExport(chat, papers, (done, total) => { if (!c.signal.aborted) setPhase({ kind: 'preparing', done, total }); }, c.signal);
      const result = buildExport(input, images);
      const bytes = zip(result.files, input.exportedAt);
      if (c.signal.aborted) return;
      save(result.fileName, bytes);
      setPhase({ kind: 'done', fileName: result.fileName, skipped: result.skipped });
    } catch {
      if (!c.signal.aborted) setPhase({ kind: 'failed' });
    }
  };

  return <Dialog open={open} onClose={onClose} title="Download your assets" className="assets-export-dialog">
    <h2>Download your assets</h2>
    <p className="muted">A .zip of your chats, diagrams, snippets (with their images) and the explanations kept in this browser, put together here. Downloaded papers aren’t included.</p>
    {phase.kind === 'preparing' && <div className="assets-export-progress" role="status" data-testid="assets-export-progress">
      <progress value={phase.total ? phase.done : undefined} max={phase.total || undefined} aria-label="Preparing your assets" />
      <p className="fine">{phase.total ? `${phase.done} of ${phase.total} snippet images` : 'Preparing your assets…'}</p>
    </div>}
    {phase.kind === 'done' && <div role="status" data-testid="assets-export-done"><p>Downloaded <strong>{phase.fileName}</strong>.</p>
      {phase.skipped.length > 0 && <ul className="fine" data-testid="assets-export-skipped">{phase.skipped.map(s => <li key={s}>{s}</li>)}</ul>}</div>}
    {phase.kind === 'failed' && <p role="alert" data-testid="assets-export-failed">Your assets couldn’t be put together. Try again.</p>}
    <div className="dialog-actions">
      <button className="secondary" onClick={onClose}>Done</button>
      <button className="primary" onClick={() => void run()} disabled={phase.kind === 'preparing'} data-testid="assets-export-run">
        {phase.kind === 'done' ? 'Download again' : phase.kind === 'failed' ? 'Try again' : 'Download .zip'}</button>
    </div>
  </Dialog>;
}
