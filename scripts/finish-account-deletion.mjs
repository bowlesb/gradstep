#!/usr/bin/env node
// Operator: finish an account deletion the account-delete function logged as
// incomplete (account_deletion_incomplete). Repeats every step safely.
// Usage: node scripts/finish-account-deletion.mjs ACCOUNT_ID
import { readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import { completeAccountDeletion } from '../supabase/functions/_shared/account-deletion.ts';

const account = process.argv[2];
if (!/^[0-9a-f-]{36}$/.test(account ?? '')) { console.error('usage: finish-account-deletion.mjs ACCOUNT_ID'); process.exit(2); }
const env = Object.fromEntries(readFileSync(new URL('../.env.staging', import.meta.url), 'utf8').split('\n').filter(l => l.includes('='))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }));
const service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const begun = await service.rpc('worker_delete_account_begin', { p_account_id: account });
if (begun.error) { console.error('begin failed:', begun.error.message); process.exit(1); }
console.log(JSON.stringify(await completeAccountDeletion(service, account, begun.data)));
