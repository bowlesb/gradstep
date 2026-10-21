// Crop or redact a support screenshot before it is sent (B5; ReportComposer's ScreenshotEditor on iPhone, iPad and Mac):
// Cover private text (the default) adds a black box per drag; Crop keeps the area dragged around (one box, a yellow
// outline). Reset edits clears both. Done renders the edited image (lib/support.ts editScreenshot); only it is uploaded.
import { type PointerEvent as ReactPointerEvent, useRef, useState } from 'react';
import { BackendError } from '../lib/backend';
import { type ScreenshotAttachment, type ScreenshotBox, editScreenshot } from '../lib/support';
import { Dialog } from './common';

type Mode = 'cover' | 'crop';
const box = (a: { x: number; y: number }, b: { x: number; y: number }): ScreenshotBox => ({ x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(a.x - b.x), h: Math.abs(a.y - b.y) });
const style = (b: ScreenshotBox) => ({ left: `${b.x * 100}%`, top: `${b.y * 100}%`, width: `${b.w * 100}%`, height: `${b.h * 100}%` });

export function ScreenshotEditor({ image, onCancel, onDone }: { image: ScreenshotAttachment; onCancel: () => void; onDone: (edited: ScreenshotAttachment) => void }) {
  const [mode, setMode] = useState<Mode>('cover');
  const [covers, setCovers] = useState<ScreenshotBox[]>([]), [crop, setCrop] = useState<ScreenshotBox | null>(null);
  const [drag, setDrag] = useState<{ start: { x: number; y: number }; now: { x: number; y: number }; px: { x: number; y: number } } | null>(null);
  const [busy, setBusy] = useState(false), [issue, setIssue] = useState<string | null>(null);
  const area = useRef<HTMLDivElement>(null);
  const point = (event: ReactPointerEvent) => {
    const r = area.current!.getBoundingClientRect();
    return { x: Math.min(1, Math.max(0, (event.clientX - r.left) / r.width)), y: Math.min(1, Math.max(0, (event.clientY - r.top) / r.height)) };
  };
  const finish = (event: ReactPointerEvent) => {
    if (!drag) return;
    const end = point(event), b = box(drag.start, end);
    setDrag(null);
    // A tap or a sliver isn't a box: under 3 px of movement, or half a percent of a side.
    if (Math.hypot(event.clientX - drag.px.x, event.clientY - drag.px.y) < 3 || b.w <= 0.005 || b.h <= 0.005) return;
    if (mode === 'cover') setCovers(c => [...c, b]); else setCrop(b);
    setIssue(null);
  };
  const done = async () => {
    if (busy) return;
    if (!crop && !covers.length) { onCancel(); return; }
    setBusy(true); setIssue(null);
    try { onDone(await editScreenshot(image, { crop, covers })); }
    catch (error) { setIssue(error instanceof BackendError && error.code === 'crop_too_small' ? 'Select a larger crop and try again.' : 'The screenshot couldn’t be edited. Try again.'); }
    finally { setBusy(false); }
  };
  const live = drag ? box(drag.start, drag.now) : null;
  return <Dialog open onClose={() => { if (!busy) onCancel(); }} title="Edit screenshot" wide className="screenshot-editor">
    <div className="dialog-heading"><h2>Edit screenshot</h2></div>
    <div className="screenshot-editor-tools">
      <span className="segmented" role="group" aria-label="Edit">
        {(['cover', 'crop'] as const).map(m => <button key={m} type="button" className={`segment${mode === m ? ' on' : ''}`} aria-pressed={mode === m} onClick={() => setMode(m)}
          data-testid={`screenshot-${m}`}>{m === 'cover' ? 'Cover private text' : 'Crop'}</button>)}
      </span>
      <button type="button" className="link small" disabled={busy || (!crop && !covers.length)} onClick={() => { setCovers([]); setCrop(null); setIssue(null); }}>Reset edits</button>
    </div>
    <p className="fine" role="status">{mode === 'cover' ? 'Drag to cover private details.' : 'Drag around the area to keep.'}</p>
    <div ref={area} className="screenshot-editor-area" data-testid="screenshot-area" style={{ aspectRatio: `${image.width} / ${image.height}`, width: `min(100%, calc(62dvh * ${(image.width / image.height).toFixed(4)}))` }}
      onPointerDown={event => { if (busy) return; event.currentTarget.setPointerCapture(event.pointerId); const p = point(event); setDrag({ start: p, now: p, px: { x: event.clientX, y: event.clientY } }); }}
      onPointerMove={event => { if (drag) setDrag({ ...drag, now: point(event) }); }} onPointerUp={finish} onPointerCancel={() => setDrag(null)}>
      <img src={image.url} alt="Screenshot to edit" draggable={false} />
      {covers.map((c, i) => <span key={i} className="screenshot-cover" style={style(c)} />)}
      {crop && <span className="screenshot-crop" style={style(crop)} />}
      {live && <span className={mode === 'cover' ? 'screenshot-cover drafting' : 'screenshot-crop'} style={style(live)} />}
    </div>
    {issue && <p className="issue" role="alert">{issue}</p>}
    <div className="dialog-actions">
      <button type="button" className="secondary" disabled={busy} onClick={onCancel}>Cancel</button>
      <button type="button" className="primary" disabled={busy} onClick={() => void done()} data-testid="screenshot-done">{busy ? 'Saving…' : 'Done'}</button>
    </div>
  </Dialog>;
}
