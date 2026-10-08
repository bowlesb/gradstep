import React, { useEffect, useRef, useState } from 'react';
import { environment } from './backend';
import { pendingSpendingEntries, recordSpendingOnce, retrySpendingObservation } from './spending-retry';
import { dollarsToMicrousd, FIRST_OBSERVATION_MONTH, latestObservationMonth, parseSpendingDraft,
  SPENDING_COMPONENTS, SPENDING_MEASURES, SpendingInputError,
  type SpendingComponent, type SpendingMeasure, type SpendingObservationRequest, type SpendingObservationReceipt } from '../../../supabase/functions/_shared/spending-observations.ts';

type RecordObservation = (ownerID: string, request: SpendingObservationRequest) => Promise<SpendingObservationReceipt>;
const help: Record<SpendingMeasure, string> = {
  commitment: 'The approved total for this component and reporting month. It replaces the prior planning amount; individual line items are not added together.',
  forecast: 'The estimated total for this component and reporting month. It replaces the prior planning amount; individual line items are not added together.',
  invoice: 'A vendor bill, recorded separately. It does not increase the planning amount or provider spending.',
  metric: 'A measured observation, not a vendor bill. It does not increase the planning amount or provider spending.',
};
const inputErrors: Record<SpendingInputError['code'], string> = {
  invalid_request: 'Review the entry and try again.', invalid_request_id: 'The entry identity is unavailable.',
  invalid_component: 'Choose a cost component.', invalid_period: 'Choose a reporting month from October 2026 through twelve months ahead.',
  invalid_measure: 'Choose an observation type.', invalid_amount: 'Use USD from 0 to 10,000 with at most six decimal places.',
  invalid_completeness: 'Enter the known amount, or leave complete evidence unchecked.',
  invalid_evidence: 'Use a reference of 3–256 letters, numbers, spaces or . _ : / - characters.',
  invalid_observed_at: 'Check this device’s clock before continuing.',
};

export function SpendingEntry({ ownerID, record, onRecorded }: { ownerID: string; record: RecordObservation; onRecorded(): void }) {
  const [open, setOpen] = useState(false), [component, setComponent] = useState<SpendingComponent>('tavily_subscription');
  const [month, setMonth] = useState(() => new Date().toISOString().slice(0, 7)), [measure, setMeasure] = useState<SpendingMeasure>('commitment');
  const [amount, setAmount] = useState(''), [complete, setComplete] = useState(false), [evidence, setEvidence] = useState('');
  const [submitted, setSubmitted] = useState<SpendingObservationRequest | null>(null), [receipt, setReceipt] = useState<SpendingObservationReceipt | null>(null);
  const [busy, setBusy] = useState(false), [error, setError] = useState(''), [pending, setPending] = useState(0), [journalError, setJournalError] = useState('');
  const sending = useRef(false), trigger = useRef<HTMLButtonElement>(null), first = useRef<HTMLSelectElement>(null);
  const refreshPending = () => { try { setPending(pendingSpendingEntries(environment, ownerID)); setJournalError(''); }
    catch { setJournalError('The retry record is unavailable. Keep this tab open and restore browser session storage before sending.'); } };
  useEffect(refreshPending, [ownerID]);
  useEffect(() => { if (open && !submitted && !receipt) first.current?.focus(); }, [open, submitted, receipt]);
  const close = () => { setOpen(false); trigger.current?.focus(); };
  const another = () => { setSubmitted(null); setReceipt(null); setError(''); setAmount(''); setComplete(false); setEvidence(''); first.current?.focus(); };
  const submit = async (event: React.FormEvent) => {
    event.preventDefault(); if (sending.current || receipt) return;
    setError('');
    try {
      sending.current = true; setBusy(true);
      const send = (request: SpendingObservationRequest) => { setSubmitted(request); return record(ownerID, request); };
      const result = submitted ? await retrySpendingObservation(environment, ownerID, submitted, send)
        : await recordSpendingOnce(environment, ownerID, parseSpendingDraft({ component, period: month + '-01', measure,
          amount_microusd: dollarsToMicrousd(amount), complete, evidence_reference: evidence.trim() }), send);
      setReceipt(result); onRecorded();
    } catch (failure) {
      setError(failure instanceof SpendingInputError ? inputErrors[failure.code]
        : failure instanceof Error ? failure.message : 'The observation was not confirmed. Retry the same entry.');
    } finally { sending.current = false; setBusy(false); refreshPending(); }
  };
  return <section className="panel spending-entry" aria-labelledby="spending-entry-title">
    <div className="section-heading"><h2 id="spending-entry-title">Record cost evidence</h2>
      <button ref={trigger} className="quiet" aria-expanded={open} aria-controls="spending-entry-form" onClick={() => open ? close() : setOpen(true)}>{open ? 'Close form' : 'Add observation'}</button></div>
    {!open && <p className="muted">Record a commitment, forecast, invoice or measured cost. Budgets and credit balances stay unchanged.</p>}
    {pending > 0 && !receipt && <p className="notice" role="status">{pending} unconfirmed {pending === 1 ? 'entry' : 'entries'} in this tab. {submitted ? 'Retry preserves the same receipt.' : 'Re-enter the same fields to retry an entry after a reload.'}</p>}
    {journalError && <p className="error" role="alert">{journalError}</p>}
    {open && <form id="spending-entry-form" onSubmit={event => void submit(event)} onKeyDown={event => { if (event.key === 'Escape' && !busy) { event.preventDefault(); close(); } }}>
      <p className="muted" id="spending-period-help">Reporting month groups the cost; it is not the vendor’s service period. Entries are permanent. Record corrections as new observations.</p>
      <fieldset disabled={busy || submitted !== null || receipt !== null}>
        <div className="spending-entry-grid">
          <label>Component<select ref={first} value={component} onChange={e => setComponent(e.target.value as SpendingComponent)}>{Object.entries(SPENDING_COMPONENTS).map(([id, title]) => <option key={id} value={id}>{title}</option>)}</select></label>
          <label>Reporting month<input type="month" required min={FIRST_OBSERVATION_MONTH} max={latestObservationMonth()} value={month} onChange={e => setMonth(e.target.value)} aria-describedby="spending-period-help" /></label>
          <label>Measure<select value={measure} onChange={e => setMeasure(e.target.value as SpendingMeasure)} aria-describedby="spending-measure-help">{SPENDING_MEASURES.map(value => <option key={value} value={value}>{value[0].toUpperCase() + value.slice(1)}</option>)}</select></label>
          <label>Amount (USD)<input inputMode="decimal" value={amount} maxLength={12} onChange={e => setAmount(e.target.value)} placeholder="Unknown" aria-describedby="spending-amount-help" /></label>
        </div>
        <p id="spending-measure-help" className="muted field-help">{help[measure]}</p>
        <p id="spending-amount-help" className="muted field-help">Use the component’s amount for the reporting month; do not mix an individual line item with a full-month total. Leave blank if unknown. Zero means a verified $0 amount.</p>
        <label className="check"><input type="checkbox" checked={complete} onChange={e => setComplete(e.target.checked)} aria-describedby="spending-complete-help" />Complete evidence</label>
        <p id="spending-complete-help" className="muted field-help">Leave unchecked if attribution or the covered period is uncertain.</p>
        <label>Evidence reference<input required minLength={3} maxLength={256} value={evidence} onChange={e => setEvidence(e.target.value)} autoComplete="off" spellCheck={false} placeholder="Vendor invoice date or internal report reference" aria-describedby="spending-evidence-help" /></label>
        <p id="spending-evidence-help" className="muted field-help">Use a short reference, without credentials, account details or invoice contents.</p>
      </fieldset>
      {submitted && <p className="muted observation-receipt">Observation time: {new Date(submitted.observed_at).toLocaleString()}<br />Request <code>{submitted.request_id}</code></p>}
      {error && <p role="alert" className="error">{error}</p>}
      {receipt ? <><p className="notice success" role="status">{receipt.replayed ? 'Already recorded; no duplicate was added.' : 'Observation recorded.'} Reporting month: {month}. Budgets and credit balances were not changed.</p>
        {month !== new Date().toISOString().slice(0, 7) && <p className="muted">Saved for {month}. The dashboard currently lists observations for {new Date().toISOString().slice(0, 7)} only.</p>}
        <button type="button" className="secondary" onClick={another}>Record another observation</button></>
        : <div className="spending-entry-actions"><button type="submit" disabled={busy || !!journalError}>{busy ? 'Recording…' : submitted ? 'Retry same entry' : 'Record observation'}</button>
          {submitted && !busy && <button type="button" className="quiet" onClick={another}>Start a different entry</button>}</div>}
    </form>}
  </section>;
}
