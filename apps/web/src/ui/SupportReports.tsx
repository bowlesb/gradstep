import { useEffect, useRef, useState } from 'react';
import { BackendError, createSupportReport, getSupportThread, listSupportReports, reportImage, replyToSupportReport, setSupportReportStatus, uploadSupportImage, type SupportReportWire, type SupportThreadWire } from '../lib/backend';
import { captureBrowserScreen, captureErrorMessage, disposeScreenshot, prepareScreenshot, type ScreenshotAttachment } from '../lib/support';
import { formatDate, Dialog, SheetTop } from './common';
import { faultSummary } from '../lib/faults';
import { ScreenshotEditor } from './ScreenshotEditor';

const WEB_VERSION = '0.1.0';

function issueMessage(error: unknown): string {
  if (error instanceof BackendError) {
    if (error.code === 'report_rate_limit') return 'You have reached the report limit for this hour. Please add details to one report and reply there.';
    if (error.code === 'connection') return 'The report could not reach support. Keep this dialog open and try again.';
    if (error.code === 'sign_in_required') return 'Sign in again before sending the report.';
    if (error.code === 'payload_too_large') return 'The screenshot is too large. Choose a smaller image.';
  }
  return 'The report could not be saved. Keep this dialog open and try again.';
}
/** A failed read of your reports (the list, or one report's thread) says it couldn't load, never that a report couldn't
 * be saved (UX audit S25). */
export function loadMessage(error: unknown, what: 'list' | 'thread'): string {
  if (error instanceof BackendError && error.code === 'sign_in_required') return what === 'list' ? 'Sign in again to see your reports.' : 'Sign in again to see this report.';
  return what === 'list' ? 'Couldn’t load your reports.' : 'Couldn’t load this report.';
}

function screenLabel(): string {
  const route = `${location.pathname}${location.pathname === '/' ? '' : location.search}`.slice(0, 48) || '/';
  // Recent faults as codes only (lib/faults.ts), so a report says which part failed.
  const faults = faultSummary(2);
  return `Browser ${route} · ${Math.max(1, Math.round(innerWidth))}×${Math.max(1, Math.round(innerHeight))}${faults ? ` · ${faults}` : ''}`.slice(0, 100);
}

export function ReportDialog({ open, onClose, account, onSent }: { open: boolean; onClose: () => void; account: string; onSent?: () => void }) {
  const file = useRef<HTMLInputElement>(null);
  const reportID = useRef(crypto.randomUUID());
  const [title, setTitle] = useState('');
  const [note, setNote] = useState('');
  const [image, setImage] = useState<ScreenshotAttachment | null>(null);
  const [attachmentID, setAttachmentID] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  // Crop or redact (B5): the editor's result replaces the preview, and only the preview is uploaded.
  const [editing, setEditing] = useState(false);

  useEffect(() => {
    if (open) return;
    reportID.current = crypto.randomUUID(); setTitle(''); setNote(''); setError(null); setSent(false); setAttachmentID(null);
    setImage(previous => { disposeScreenshot(previous); return null; });
  }, [open]);
  useEffect(() => () => disposeScreenshot(image), [image]);

  const replaceImage = async (source: Blob) => {
    setError(null);
    try {
      const next = await prepareScreenshot(source);
      setImage(previous => { disposeScreenshot(previous); return next; }); setAttachmentID(crypto.randomUUID());
    } catch (reason) { setError(captureErrorMessage(reason)); }
  };
  const capture = async () => {
    setBusy(true); setError(null);
    try {
      const next = await captureBrowserScreen();
      setImage(previous => { disposeScreenshot(previous); return next; }); setAttachmentID(crypto.randomUUID());
    } catch (reason) { setError(captureErrorMessage(reason)); }
    finally { setBusy(false); }
  };
  const send = async () => {
    const text = note.trim(); if (!text || busy) return;
    setBusy(true); setError(null);
    try {
      const id = reportID.current;
      await createSupportReport({ id, title: (title.trim() || 'Browser issue').slice(0, 160), note: text.slice(0, 10_000), appVersion: WEB_VERSION, build: `web ${__WEB_BUILD__}`, osVersion: navigator.platform.slice(0, 100), screen: screenLabel() }, account);
      if (image && attachmentID) {
        await uploadSupportImage(new Uint8Array(await image.blob.arrayBuffer()), image.mediaType, account, id, attachmentID);
      }
      setSent(true); onSent?.();
    } catch (reason) { setError(image ? `The report was saved, but its screenshot was not uploaded. ${issueMessage(reason)}` : issueMessage(reason)); }
    finally { setBusy(false); }
  };

  return <Dialog open={open} onClose={() => { if (!busy) onClose(); }} title="Report an issue" wide={false}>
    {sent ? <>
      <div className="dialog-heading"><h2>Report sent</h2></div>
      <p>Your report is in the support queue. You can follow its status and reply under <strong>My reports</strong>.</p>
      <div className="dialog-actions"><button className="primary" onClick={onClose}>Done</button></div>
    </> : <>
      <div className="dialog-heading"><h2>Report this screen</h2></div>
      <p className="muted">Tell us what went wrong and what you expected. A screenshot makes visual problems much easier to fix.</p>
      <label className="support-field">Short title <span className="fine">optional</span>
        <input value={title} onChange={event => setTitle(event.target.value)} maxLength={160} placeholder="e.g. Add paper button is disabled" data-testid="report-title" disabled={busy} />
      </label>
      <label className="support-field">What happened?
        <textarea value={note} onChange={event => setNote(event.target.value)} maxLength={10_000} rows={6} placeholder="Describe the steps and what you expected…" data-testid="report-note" disabled={busy} />
      </label>
      <section className="support-screenshot" aria-label="Screenshot attachment">
        <div className="support-section-head"><strong>Screenshot</strong><span className="fine">optional</span></div>
        {image ? <div className="support-preview"><img src={image.url} alt="Screenshot preview" data-testid="report-preview" />
          <span className="support-preview-actions">
            <button className="secondary small" onClick={() => setEditing(true)} disabled={busy} data-testid="report-edit">Crop or redact</button>
            <button className="secondary small" onClick={() => { disposeScreenshot(image); setImage(null); setAttachmentID(null); }} disabled={busy}>Remove</button>
          </span></div> : <p className="fine">Capture the current browser tab, or choose a screenshot file.</p>}
        {image && editing && <ScreenshotEditor image={image} onCancel={() => setEditing(false)}
          onDone={edited => { setEditing(false); setImage(previous => { disposeScreenshot(previous); return edited; }); setAttachmentID(crypto.randomUUID()); }} />}
        <div className="support-image-actions">
          <button className="secondary small" onClick={() => void capture()} disabled={busy}><span aria-hidden="true">⌁</span> Capture this screen…</button>
          <button className="secondary small" onClick={() => file.current?.click()} disabled={busy}>Choose image…</button>
          <input ref={file} type="file" accept="image/png,image/jpeg" hidden onChange={event => { const selected = event.currentTarget.files?.[0]; event.currentTarget.value = ''; if (selected) void replaceImage(selected); }} data-testid="report-file" />
        </div>
        <p className="fine">The browser will ask which tab or window to share. Only this preview is uploaded. Crop or cover private details. The image is resized and stripped of metadata before upload.</p>
      </section>
      {error && <p className="issue" role="alert">{error}</p>}
      <div className="dialog-actions"><button className="secondary" onClick={onClose} disabled={busy}>Cancel</button><button className="primary" onClick={() => void send()} disabled={busy || !note.trim()} data-testid="report-send">{busy ? 'Sending…' : 'Send report'}</button></div>
    </>}
  </Dialog>;
}

export function ReportsDialog({ open, onClose, account }: { open: boolean; onClose: () => void; account: string }) {
  const [reports, setReports] = useState<SupportReportWire[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [thread, setThread] = useState<SupportThreadWire | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const reload = async () => {
    setLoading(true); setError(null);
    try { setReports(await listSupportReports(account)); } catch (reason) { setError(loadMessage(reason, 'list')); }
    finally { setLoading(false); }
  };
  useEffect(() => { if (open) { setSelected(null); setThread(null); void reload(); } }, [open, account]);
  useEffect(() => {
    if (!selected) return;
    let live = true; setLoading(true); setError(null);
    void getSupportThread(selected, account).then(value => { if (live) setThread(value); }).catch(reason => { if (live) setError(loadMessage(reason, 'thread')); }).finally(() => { if (live) setLoading(false); });
    return () => { live = false; };
  }, [selected, account]);
  const openReport = (id: string) => { setSelected(id); setThread(null); };
  const back = () => { setSelected(null); setThread(null); };
  return <Dialog open={open} onClose={onClose} title="My reports" wide>
    {/* Read again each time the dialog opens; a failure offers Try again, never a standing Refresh (UX audit S25). */}
    <SheetTop onClose={onClose} testID="reports-close">{selected && thread
      ? <><button className="link" onClick={back}>‹ My reports</button><span className="fine">{thread.report.status.replaceAll('_', ' ')}</span></>
      : <h2>My reports</h2>}</SheetTop>
    {selected && thread ? <ReportThread thread={thread} account={account} onRefresh={() => { void getSupportThread(selected, account).then(setThread).catch(reason => setError(loadMessage(reason, 'thread'))); }} />
      : <>
        {loading && <p className="muted">Loading reports…</p>}
        {!loading && !reports.length && !error && <p className="muted">Your submitted reports and replies will appear here.</p>}
        <div className="support-report-list">{reports.map(report => <button className="support-report-row" key={report.id} onClick={() => openReport(report.id)}>
          <span><strong>{report.title}</strong><small>{report.status.replaceAll('_', ' ')} · {formatDate(Date.parse(report.created_at))}</small></span><span aria-hidden="true">›</span>
        </button>)}</div>
        {error && <div className="support-load-issue" role="alert" data-testid="reports-load-issue"><p className="issue">{error}</p>
          {!loading && <button className="secondary small" onClick={() => void reload()}>Try again</button>}</div>}
      </>}
  </Dialog>;
}

function ReportThread({ thread, account, onRefresh }: { thread: SupportThreadWire; account: string; onRefresh: () => void }) {
  const [reply, setReply] = useState(''); const [busy, setBusy] = useState(false); const [error, setError] = useState<string | null>(null); const [images, setImages] = useState<Record<string, string>>({});
  useEffect(() => {
    // data: URLs: the page's image policy admits 'self' and data: only (vite.config.ts), never blob:.
    let live = true;
    const dataURL = (bytes: Uint8Array) => { let s = ''; for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode(...bytes.subarray(i, i + 8192)); return `data:image/png;base64,${btoa(s)}`; };
    void Promise.all(thread.attachments.map(async attachment => { try { return [attachment.id, dataURL(new Uint8Array(await reportImage(attachment.id, account)))] as const; } catch { return null; } })).then(values => {
      if (live) setImages(Object.fromEntries(values.filter((value): value is readonly [string, string] => !!value)));
    });
    return () => { live = false; };
  }, [thread, account]);
  const sendReply = async () => {
    const text = reply.trim(); if (!text || busy) return; setBusy(true); setError(null);
    try { await replyToSupportReport(crypto.randomUUID(), thread.report.id, text, account); setReply(''); onRefresh(); }
    catch (reason) { setError(issueMessage(reason)); } finally { setBusy(false); }
  };
  const setStatus = async (status: 'open' | 'verified') => {
    setBusy(true); setError(null); try { await setSupportReportStatus(crypto.randomUUID(), thread.report.id, status, account); onRefresh(); } catch (reason) { setError(issueMessage(reason)); } finally { setBusy(false); }
  };
  return <>
    <h2 className="support-thread-title">{thread.report.title}</h2><p className="support-thread-note">{thread.report.note}</p>
    {thread.attachments.length > 0 && <section className="support-thread-images"><strong>Shared screenshots</strong>{thread.attachments.map(attachment => images[attachment.id] ? <img key={attachment.id} src={images[attachment.id]} alt="Screenshot shared with support" /> : <span className="fine" key={attachment.id}>Screenshot unavailable</span>)}</section>}
    <section className="support-messages"><strong>Replies</strong>{thread.messages.length ? thread.messages.map(message => <div className={message.is_operator ? 'support-message operator' : 'support-message'} key={message.id}><small>{message.is_operator ? 'Support' : 'You'} · {formatDate(Date.parse(message.created_at))}</small><p>{message.body}</p></div>) : <p className="fine">No reply yet.</p>}</section>
    <label className="support-field">Reply to support<textarea value={reply} onChange={event => setReply(event.target.value)} rows={3} maxLength={10_000} disabled={busy} placeholder="Add context or tell us whether a fix works…" /></label>
    {error && <p className="issue" role="alert">{error}</p>}
    <div className="dialog-actions"><button className="secondary" onClick={() => void setStatus(thread.report.status === 'verified' ? 'open' : 'verified')} disabled={busy}>{thread.report.status === 'verified' ? 'Reopen issue' : 'Confirm fixed'}</button><button className="primary" onClick={() => void sendReply()} disabled={busy || !reply.trim()}>{busy ? 'Saving…' : 'Send reply'}</button></div>
  </>;
}
