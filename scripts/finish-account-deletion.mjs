#!/usr/bin/env node
// Operator: finish an account deletion the account-delete function logged as
// incomplete (account_deletion_incomplete). Repeats every step safely.
// Usage: node scripts/finish-account-deletion.mjs ACCOUNT_ID --confirm=ACCOUNT_ID
//
// Safeguards (review A10, 2026-10-21): worker_delete_account_begin closes and deletes an open account too, so this
// script only continues a deletion that already began. It refuses unless (1) the target is the recorded staging
// project (infra/account.json, .env.staging's ref and URL), (2) the UUID is typed twice (--confirm), and (3) the
// account is already closed (worker_account_deletion_status says closed). A wrong or pasted UUID of an open account
// is refused before any write.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const USAGE = 'usage: finish-account-deletion.mjs ACCOUNT_ID --confirm=ACCOUNT_ID';

export class Refused extends Error {}

/** The account, typed twice. Anything else (a second positional, an unknown flag) is refused. */
export function parseArguments(argv) {
  const positional = argv.filter(a => !a.startsWith('--'));
  const flags = argv.filter(a => a.startsWith('--'));
  const account = positional[0];
  if (positional.length !== 1 || !UUID.test(account ?? '')) throw new Refused(USAGE);
  const confirm = flags.find(f => f.startsWith('--confirm='))?.slice('--confirm='.length);
  if (flags.length !== 1 || confirm === undefined) throw new Refused(`${USAGE}\nType the account UUID again with --confirm= to continue.`);
  if (confirm !== account) throw new Refused('The --confirm UUID does not match the account; nothing was changed.');
  return { account };
}

/** The recorded staging project, and only it: .env.staging's ref and URL must both name it. */
export function assertStagingTarget(env, manifest) {
  const staging = manifest?.projects?.staging?.id;
  if (typeof staging !== 'string' || !/^[a-z]{20}$/.test(staging)) throw new Refused('infra/account.json does not record the staging project.');
  if (env.SUPABASE_PROJECT_REF !== staging) throw new Refused('.env.staging does not name the recorded staging project; refusing.');
  let host = '';
  try { host = new URL(env.SUPABASE_URL ?? '').host; } catch { /* refused below */ }
  if (host !== `${staging}.supabase.co`) throw new Refused('SUPABASE_URL is not the recorded staging project; refusing.');
  if (!env.SUPABASE_SERVICE_ROLE_KEY) throw new Refused('.env.staging has no service key.');
  return staging;
}

/** Continues a deletion only for an account that is already closed. `complete` is completeAccountDeletion. */
export async function finishClosedAccount(service, account, complete) {
  const status = await service.rpc('worker_account_deletion_status', { p_account_id: account });
  if (status.error) throw new Error('status_unavailable');
  if (status.data?.closed !== true) {
    throw new Refused(status.data?.closed === false
      ? 'This account is open (not closed). Only a deletion that already began can be finished here; nothing was changed.'
      : 'No such account; nothing was changed.');
  }
  const begun = await service.rpc('worker_delete_account_begin', { p_account_id: account });
  if (begun.error) throw new Error(`begin failed: ${begun.error.message}`);
  return complete(service, account, begun.data);
}

function dotenv(text) {
  return Object.fromEntries(text.split('\n').filter(l => l.includes('=') && !l.trimStart().startsWith('#'))
    .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]; }));
}

async function main() {
  const { account } = parseArguments(process.argv.slice(2));
  const env = dotenv(readFileSync(new URL('../.env.staging', import.meta.url), 'utf8'));
  assertStagingTarget(env, JSON.parse(readFileSync(new URL('../infra/account.json', import.meta.url), 'utf8')));
  const { createClient } = await import('@supabase/supabase-js');
  const { completeAccountDeletion } = await import('../supabase/functions/_shared/account-deletion.ts');
  const service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  console.log(JSON.stringify(await finishClosedAccount(service, account, completeAccountDeletion)));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(error instanceof Refused ? error.message : error instanceof Error ? error.message : 'failed'); process.exit(error instanceof Refused ? 2 : 1); });
}
