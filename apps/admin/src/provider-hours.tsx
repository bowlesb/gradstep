import React, { useEffect, useRef, useState } from 'react';
import type { ProviderHour } from './backend';
import { moment, percent } from './charts';

// Reliability's hour-by-hour provider table (docs/architecture/RESILIENCE.md): every outside provider's calls per hour
// by outcome — what the Health tab's "Provider errors" chart and its Attention rules summarise.

// OpenRouter is the only model gateway since 2026-10-18; the direct model providers appear only in older hours.
export const PROVIDER_NAMES: Record<string, string> = { openrouter: 'OpenRouter (all AI)', anthropic: 'Anthropic direct (retired)', deepseek: 'DeepSeek direct (retired)', google: 'Google direct (retired)', tavily: 'Tavily',
  crossref: 'Crossref', datacite: 'DataCite', openalex: 'OpenAlex', huggingface: 'Hugging Face', arxiv: 'arXiv (never: refused)' };
export const providerName = (provider: string) => PROVIDER_NAMES[provider] ?? provider;

export function ProviderHours({ load, reloadKey }: { load: (hours: number) => Promise<ProviderHour[]>; reloadKey: number }) {
  const [rows, setRows] = useState<ProviderHour[] | null>(null);
  const [all, setAll] = useState(false);
  const [error, setError] = useState('');
  const request = useRef(0);
  useEffect(() => {
    const id = ++request.current;
    setError('');
    load(48).then(next => { if (id === request.current) setRows(next); })
      .catch(e => { if (id === request.current) setError(e instanceof Error ? e.message : 'Provider health is unavailable.'); });
  }, [load, reloadKey]);
  return <section className="panel provider-hours" aria-labelledby="provider-hours-title">
    <div className="chart-heading"><div><h2 id="provider-hours-title">Providers, hour by hour</h2>
      <p className="muted">Every call our servers made to an outside provider in the last 48 hours. Failed: overloaded, 5xx, timeouts and dropped connections.
        Throttled: 429s. Paused: answered at once while the provider's breaker was open. Refused: other 4xx (our request, not their health).</p></div></div>
    {error && <p className="error" role="alert">{error}</p>}
    {rows && rows.length > 0 && <div className="toolbar"><div className="segmented" role="group" aria-label="Hours shown">
      <button type="button" className={!all ? 'selected' : ''} aria-pressed={!all} onClick={() => setAll(false)}>Hours with problems</button>
      <button type="button" className={all ? 'selected' : ''} aria-pressed={all} onClick={() => setAll(true)}>Every hour</button></div></div>}
    {!rows ? !error && <p className="empty">Loading…</p> : !rows.length ? <p className="empty">No provider calls in the last 48 hours.</p>
      : !all && !rows.some(r => r.failed || r.throttled || r.breaker_open || r.rejected) ? <p className="empty">No failed, throttled, paused or refused calls in the last 48 hours.</p> :
      <div className="table-scroll"><table>
        <thead><tr><th>Hour</th><th>Provider</th><th>Calls</th><th>Failed</th><th>Throttled</th><th>Paused</th><th>Refused</th><th>Avg time</th><th>Longest</th><th>Retry-After</th></tr></thead>
        <tbody>{rows.filter(r => all || r.failed || r.throttled || r.breaker_open || r.rejected).map(r => {
          const bad = r.calls >= 20 && (r.failed + r.throttled) / r.calls >= 0.05;
          return <tr key={`${r.hour}-${r.provider}`} className={bad ? 'bad-row' : undefined}>
            <td>{moment.format(new Date(r.hour))}</td><td>{providerName(r.provider)}</td><td>{r.calls.toLocaleString()}</td>
            <td>{r.failed ? `${r.failed.toLocaleString()} (${percent(r.failed / r.calls)})` : '—'}</td>
            <td>{r.throttled ? `${r.throttled.toLocaleString()} (${percent(r.throttled / r.calls)})` : '—'}</td>
            <td>{r.breaker_open || '—'}</td><td>{r.rejected || '—'}</td>
            <td>{r.latency_ms_avg == null ? '—' : `${(r.latency_ms_avg / 1000).toFixed(1)} s`}</td>
            <td>{r.latency_ms_max ? `${(r.latency_ms_max / 1000).toFixed(1)} s` : '—'}</td>
            <td>{r.retry_after_max_s == null ? '—' : `${r.retry_after_max_s} s`}</td>
          </tr>;
        })}</tbody>
      </table></div>}
  </section>;
}
