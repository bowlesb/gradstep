// Settle unknown streaming charges from saved, read-only provider metadata. No inference or credentials.
// Dry by default; --apply requires the resulting ledger to match the saved account/key total.
import { readFileSync, writeFileSync, readdirSync, openSync, closeSync, unlinkSync, renameSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { SpendLedger, generationCharge } from './model-bakeoff-support.mjs';

const root = '.artifacts/bakeoff', source = `${root}/continuation`, apply = process.argv.includes('--apply');
const lock = openSync(`${root}/paid-run.lock`, 'wx');
try {
  writeFileSync(lock, String(process.pid));
  const ledger = new SpendLedger(`${root}/spend-ledger.json`, 10);
  const settlements = ledger.rows.filter(r => r.cost == null).map(row => {
    const file = `${source}/${row.generation}.json`, bytes = readFileSync(file), response = JSON.parse(bytes);
    return { hold: row.id, generation: row.generation, model: row.model, previous_hold: row.hold,
      cost: generationCharge(row, response), checked_at: response.checked_at,
      metadata_sha256: createHash('sha256').update(bytes).digest('hex') };
  });
  const balance = JSON.parse(readFileSync(`${source}/balance-start.json`));
  const total = ledger.actual + settlements.reduce((s, r) => s + r.cost, 0);
  if (balance.key.status !== 200 || balance.credits.status !== 200
    || Math.abs(total - balance.key.usage) > 1e-6 || Math.abs(total - balance.credits.total_usage) > 1e-6)
    throw new Error('The reconciled ledger does not match provider account/key usage');
  const receipt = { schema: 'bakeoff-billing-reconciliation-v1', checked_at: balance.checked_at,
    prior_reported: ledger.actual, released_reservations: ledger.outstanding, settlements,
    total_cost: total, outstanding: 0, provider_usage: balance.key.usage, funded: balance.credits.total_credits };
  if (apply) {
    if (!settlements.length) throw new Error('No outstanding charges; preserve the earlier reconciliation receipt');
    const updates = [];
    // Keep the original streamed cost and outcome. A billed timeout remains a failed answer.
    for (const model of readdirSync(`${root}/runs`)) for (const name of readdirSync(`${root}/runs/${model}`)) {
      const file = `${root}/runs/${model}/${name}`, record = JSON.parse(readFileSync(file));
      const recovered = settlements.filter(r => record.generations?.includes(r.generation));
      if (!recovered.length) continue;
      if (record.billing_reconciliation) throw new Error('Run already reconciled; refusing to add the charge twice');
      record.stream_reported_cost = record.cost;
      record.cost += recovered.reduce((s, r) => s + r.cost, 0);
      record.billing_reconciliation = recovered;
      updates.push({ file, record });
    }
    writeFileSync(`${source}/ledger-before-reconciliation.json`, JSON.stringify(ledger.rows, null, 2));
    for (const row of settlements) {
      ledger.settle(row.hold, row.cost);
      ledger.rows.find(r => r.id === row.hold).reconciliation = { source: 'generation.total_cost', checked_at: row.checked_at, metadata_sha256: row.metadata_sha256 };
    }
    ledger.save();
    for (const { file, record } of updates) { writeFileSync(`${file}.tmp`, JSON.stringify(record, null, 1)); renameSync(`${file}.tmp`, file); }
    writeFileSync(`${source}/billing-reconciled.json`, JSON.stringify(receipt, null, 2));
  }
  console.log(JSON.stringify({ apply, ...receipt }));
} finally { closeSync(lock); unlinkSync(`${root}/paid-run.lock`); }
