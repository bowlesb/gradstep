import { useEffect, useState } from 'react';

/** Workflow checks (docs/architecture/WORKFLOW_CHECKS.md): the latest result of each check and its recent history. */
export interface WorkflowChecks {
  generated_at: string;
  last_runs: Record<string, { started_at: string; trigger: string; passed: number; failed: number; warned: number; skipped: number; cost_microusd: number }>;
  checks: { check_id: string; latest: { status: Status; reason: string | null; at: string; suite: string } | null; history: { at: string; status: Status; suite: string }[] }[];
}
type Status = 'pass' | 'fail' | 'warn' | 'skip';
const when = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
const label: Record<Status, string> = { pass: 'Pass', fail: 'Fail', warn: 'Warning', skip: 'Skipped' };

export function WorkflowChecksPanel({ load, reloadKey }: { load: () => Promise<WorkflowChecks | null>; reloadKey: number }) {
  const [data, setData] = useState<WorkflowChecks | null>(null);
  const [error, setError] = useState(false);
  useEffect(() => { let live = true; load().then(d => { if (live) { setData(d); setError(false); } }, () => { if (live) setError(true); }); return () => { live = false; }; }, [load, reloadKey]);
  if (error) return <section className="panel"><h2>Workflow checks</h2><p className="empty">Couldn't load workflow checks.</p></section>;
  if (!data) return null;
  const failing = data.checks.filter(c => c.latest?.status === 'fail');
  const order: Record<Status, number> = { fail: 0, warn: 1, skip: 2, pass: 3 };
  const checks = [...data.checks].sort((a, b) => order[a.latest?.status ?? 'skip'] - order[b.latest?.status ?? 'skip'] || a.check_id.localeCompare(b.check_id));
  return <section className="panel" aria-labelledby="checks-title">
    <div className="section-heading"><h2 id="checks-title">Workflow checks</h2>
      <span className={'badge plain' + (failing.length ? ' warning' : ' positive')}>{failing.length ? `${failing.length} failing` : 'All passing'}</span></div>
    <p className="muted">Real user actions run against staging after deploys and on a schedule. {Object.entries(data.last_runs).map(([suite, run]) =>
      `${suite}: ${when.format(new Date(run.started_at))} (${run.passed} passed${run.failed ? `, ${run.failed} failed` : ''})`).join(' · ')}</p>
    {checks.length === 0 ? <p className="empty">No runs recorded yet.</p> :
    <table><thead><tr><th>Check</th><th>Latest</th><th>Reason</th><th>History</th></tr></thead><tbody>
      {checks.map(c => <tr key={c.check_id}>
        <td><code>{c.check_id}</code></td>
        <td><span className={`check-status ${c.latest?.status ?? 'skip'}`}>{label[c.latest?.status ?? 'skip']}</span>{c.latest && <small className="muted"> {when.format(new Date(c.latest.at))}</small>}</td>
        <td className="reason">{c.latest?.reason ?? ''}</td>
        <td><span className="history" aria-label={`${c.history.filter(h => h.status === 'fail').length} failures in ${c.history.length} runs`}>
          {c.history.map((h, i) => <i key={i} className={h.status} title={`${when.format(new Date(h.at))} · ${h.suite} · ${label[h.status]}`} />)}</span></td>
      </tr>)}
    </tbody></table>}
  </section>;
}
