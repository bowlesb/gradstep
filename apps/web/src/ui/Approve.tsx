// "Approve from your phone": this browser shows a QR code and a comparison code until an approved device adds it.
// docs/architecture/BROWSER_READER.md#approving-this-browser-from-another-device
import { useEffect, useMemo, useState } from 'react';
import { displayCode, qrPath } from '../lib/approval';
import { BackendError } from '../lib/backend';
import { type AwaitingApproval, type Preparation, checkApproval, requestApproval } from '../lib/keys';

/** Bounded backoff between checks; the request is re-checked (and renewed if it expired) about once a minute. */
export const POLL = { first: 2_000, factor: 1.5, maximum: 10_000, renewEvery: 60_000, giveUpAfter: 30 * 60_000 };

const sleep = (ms: number, signal: AbortSignal) => new Promise<void>((resolve, reject) => {
  const timer = setTimeout(resolve, ms);
  signal.addEventListener('abort', () => { clearTimeout(timer); reject(signal.reason); }, { once: true });
});
const transient = (error: unknown) => error instanceof BackendError && error.code === 'connection';

export function ApproveFromPhone({ account, onResult, onIssue, onUseCode, attempt }: {
  account: string; attempt: number;
  onResult: (result: Preparation) => void; onIssue: (error: unknown) => void; onUseCode: () => void;
}) {
  const [request, setRequest] = useState<AwaitingApproval | null>(null);
  const [offline, setOffline] = useState(false);
  const [stopped, setStopped] = useState(false);
  const [round, setRound] = useState(0);

  useEffect(() => {
    const controller = new AbortController(), { signal } = controller;
    setStopped(false); setOffline(false);
    (async () => {
      const started = Date.now();
      let renewed = 0, delay = POLL.first;
      const renew = async () => {
        const step = await requestApproval(account, signal);
        renewed = Date.now();
        if (step.kind === 'awaiting_approval') { setRequest(current => current?.payload === step.payload ? current : step); return false; }
        onResult(step); return true;
      };
      if (await renew()) return;
      while (!signal.aborted) {
        await sleep(delay, signal);
        delay = Math.min(delay * POLL.factor, POLL.maximum);
        try {
          const done = await checkApproval(account, signal);
          if (done) { onResult(done); return; }
          if (Date.now() - renewed >= POLL.renewEvery && await renew()) return;
          setOffline(false);
        } catch (error) {
          if (!transient(error)) throw error;
          setOffline(true); // keep waiting; the network may come back
        }
        if (Date.now() - started >= POLL.giveUpAfter) { setStopped(true); return; }
      }
    })().catch(error => { if (!signal.aborted) onIssue(error); });
    return () => controller.abort();
  }, [account, attempt, round, onResult, onIssue]);

  const qr = useMemo(() => request && qrPath(request.payload), [request]);
  return (
    <>
      <h1>Restore your private library</h1>
      <p className="muted">Your private conversations and notes are encrypted with keys held on your devices. Approve this browser from
        your iPhone or iPad to add it.</p>
      <ol className="approve-steps">
        <li>On your iPhone or iPad, open Gradstep › Settings › Account › <strong>Add a device</strong>.</li>
        <li>Scan this code, then check that your phone shows the same number.</li>
      </ol>
      <figure className="approve-qr" data-testid="approval-qr" data-payload={request?.payload}>
        {qr ? (
          <svg viewBox={`-4 -4 ${qr.size + 8} ${qr.size + 8}`} role="img" aria-label="QR code that approves this browser" shapeRendering="crispEdges">
            <rect x={-4} y={-4} width={qr.size + 8} height={qr.size + 8} fill="#ffffff" />
            <path d={qr.path} fill="#000000" />
          </svg>
        ) : <div className="spinner" aria-label="Preparing a code" />}
      </figure>
      {request && <p className="approve-code">Your phone should show <output className="mono" data-testid="approval-code">{displayCode(request.code)}</output></p>}
      {stopped ? (
        <p className="fine" role="status">Stopped waiting. <button type="button" className="link" onClick={() => setRound(r => r + 1)}>Show a new code</button></p>
      ) : request && (
        <p className="fine approve-status" role="status" data-testid="approval-status">
          <span className="spinner small" aria-hidden="true" /> {offline ? 'Can’t reach Gradstep. Still trying…' : 'Waiting for approval…'}
        </p>
      )}
      <p className="fine">No camera on the other device? Open Gradstep there and choose Review on “A new device is waiting”, then compare the number.</p>
      <button type="button" className="secondary" onClick={onUseCode} data-testid="use-recovery-code">Use recovery code instead</button>
    </>
  );
}
