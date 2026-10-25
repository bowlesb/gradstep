// Your AI usage (migration 0144, `v1_ai_usage`; reported tokens only, 0160): the server's activity and part names cover
// everything the chat function, the provider ledger and the operation kinds can record, and the clients (browser
// lib/ai-usage.ts, Swift AIUsage.swift) know exactly the server's names. A new chat action, route or kind fails here until
// it is named for readers. Each function is read from the newest migration that defines it.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

const root = new URL('../../', import.meta.url);
const read = (path: string) => readFileSync(new URL(path, root), 'utf8');
const migrations = readdirSync(new URL('supabase/migrations/', root)).filter(f => f.endsWith('.sql')).sort();
/** The newest migration that defines a function, and that definition. */
function latest(name: string): { sql: string; body: string } {
  let found: { sql: string; body: string } | null = null;
  const definition = new RegExp(`create (?:or replace )?function ${name.replace(/\./g, '\\.')}\\(`);
  for (const file of migrations) {
    const sql = read(`supabase/migrations/${file}`);
    const start = sql.search(definition);
    if (start >= 0) found = { sql, body: sql.slice(start, sql.indexOf('$$;', start)) };
  }
  assert.ok(found, name);
  return found!;
}
const fn = (name: string) => latest(name).body;
const usage = latest('public.v1_ai_usage').sql;
const quoted = (text: string) => new Set([...text.matchAll(/'([a-z_]+)'/g)].map(m => m[1]));
/** The values of the newest `check(<column> in (...))` for a constraint across all migrations. */
function latestCheck(column: string, constraint: string): string[] {
  let found: string[] | null = null;
  for (const file of migrations) {
    const sql = read(`supabase/migrations/${file}`);
    for (const m of sql.matchAll(new RegExp(`(?:add constraint ${constraint}\\s+check|${column} text not null check)\\s*\\(\\s*${column}\\s+in\\s*\\(([^)]*)\\)`, 'gi')))
      found = [...m[1].matchAll(/'([a-z_]+)'/g)].map(x => x[1]);
  }
  assert.ok(found, constraint);
  return found!;
}
const activityFn = fn('app_private.usage_activity'), partFn = fn('app_private.usage_part');
const outputs = (body: string) => new Set([...body.matchAll(/then '([a-z_]+)'/g), ...body.matchAll(/else '([a-z_]+)'/g)].map(m => m[1]));
const ACTIVITIES = outputs(activityFn), PARTS = outputs(partFn);

test('every chat action the function accepts has an activity', () => {
  const chat = read('supabase/functions/_shared/chat.ts');
  const actions = [...(/const CHAT_ACTIONS: readonly string\[\] = \[([^\]]*)\]/.exec(chat)![1]).matchAll(/'([a-z_]+)'/g)].map(m => m[1]);
  assert.ok(actions.length >= 10);
  const named = quoted(activityFn);
  // The paper's AI Explainer settles as an answer (chat_endings.action 'answer', no migration), so it is listed as Chat.
  const COUNTED_AS_CHAT = ['paper_explainer'];
  for (const action of actions) assert.ok(named.has(action) || COUNTED_AS_CHAT.includes(action), `chat action ${action}`);
  // And how a settled chat names itself (chat_endings.action).
  for (const action of latestCheck('action', 'chat_endings_action_check')) if (!['answer', 'unknown'].includes(action)) assert.ok(named.has(action), `ending action ${action}`);
});

test('the chat answer\'s extra calls are their own parts', () => {
  const followUps = /name: '([a-z_]+)'/.exec(read('supabase/functions/_shared/chat-follow-ups.ts'))![1];
  // The study map's tool is gone (Study mode's notes ride in the answer, 2026-10-22); its old calls keep their name.
  const studyMap = 'update_study_map';
  const title = /purpose: '([a-z_]+)'/.exec(read('supabase/functions/_shared/chat.ts'))![1];
  assert.match(partFn, new RegExp(`p_feature='${followUps}' then 'suggestions'`));
  assert.match(partFn, new RegExp(`p_feature='${studyMap}' then 'study_map'`));
  assert.match(partFn, new RegExp(`p_feature='${title}' then 'title'`));
});

test('every provider route and operation kind is named', () => {
  const named = quoted(partFn);
  for (const route of latestCheck('route', 'provider_attempts_route_check')) assert.ok(route === 'chat' || named.has(route), `route ${route}`);
  const kinds = latestCheck('kind', 'metered_operations_kind_check');
  assert.ok(kinds.includes('recommend') && kinds.includes('podcast'));
  for (const kind of kinds) assert.match(activityFn, new RegExp(`p_kind='${kind}'`), `kind ${kind}`);
});

test('the reader\'s query accepts exactly the activities the server names, and the clients know them all', () => {
  const accepted = /p_activity not in \(([^)]*)\)/.exec(fn('public.v1_ai_usage'))![1];
  const acceptedSet = new Set([...accepted.matchAll(/'([a-z_]+)'/g)].map(m => m[1]));
  assert.deepEqual([...acceptedSet].sort(), [...ACTIVITIES].sort());
  const web = read('apps/web/src/lib/ai-usage.ts');
  const list = (name: string) => [...(new RegExp(`export const ${name} = \\[([^\\]]*)\\]`).exec(web)![1]).matchAll(/'([a-z_]+)'/g)].map(m => m[1]);
  assert.deepEqual([...list('USAGE_ACTIVITIES')].sort(), [...ACTIVITIES].sort());
  assert.deepEqual([...list('USAGE_PARTS')].sort(), [...PARTS].sort());
  const swift = read('apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/AIUsage.swift');
  const cases = (name: string) => {
    const body = new RegExp(`enum ${name}: [^{]*\\{([\\s\\S]*?)\\n\\n`).exec(swift)![1];
    return [...body.matchAll(/case ([^\n]*)/g)].flatMap(m => m[1].split(',').map(c => c.trim())).map(c => /= "([a-z_]+)"/.exec(c)?.[1] ?? c.split(' ')[0]);
  };
  assert.deepEqual(cases('AIUsageActivity').sort(), [...ACTIVITIES].sort());
  assert.deepEqual(cases('AIUsagePartName').sort(), [...PARTS].sort());
});

test('the reader sees only their own account, in credits, without private fields', () => {
  const rpc = fn('public.v1_ai_usage');
  assert.match(rpc, /a uuid:=app_private\.require_actor\(\)/);
  assert.match(rpc, /worker_consume_request\(a,'account-usage'\)/);
  assert.match(rpc, /app_private\.usage_operations\(a,since\)/);
  assert.doesNotMatch(usage, /create (?:or replace )?function public\.v1_ai_usage\([^)]*p_account/);
  assert.match(usage, /security definer set search_path=''/);
  assert.match(usage, /revoke all on function public\.v1_ai_usage\(integer,text,timestamptz,uuid,integer\) from public,anon;/);
  assert.match(usage, /grant execute on function public\.v1_ai_usage\(integer,text,timestamptz,uuid,integer\) to authenticated;/);
  for (const helper of ['usage_part(text,text)', 'usage_activity(text,text,text[],text[])', 'usage_operations(uuid,timestamptz)', 'usage_parts(uuid,uuid)', 'usage_reported(text,jsonb)'])
    assert.ok(latest(`app_private.${helper.slice(0, helper.indexOf('('))}`).sql.includes(`revoke all on function app_private.${helper} from public,anon,authenticated;`), helper);
  // What leaves the database: no dollars, provider ids, request digests or transport metadata.
  const reply = rpc.slice(rpc.indexOf('jsonb_build_object'));
  assert.doesNotMatch(reply, /microusd|provider_request_id|request_sha256|transport_metadata|receipt_metadata/);
});

test('tokens are the provider\'s count: a hold estimate or an estimate is never shown as used (0160)', () => {
  // Reported: succeeded, rejected before processing (zero) or reconciled from the provider's record, and not marked estimated.
  assert.match(fn('app_private.usage_reported'), /p_state in \('succeeded','rejected','reconciled'\) and coalesce\(\(p_units->>'estimated'\)::bigint,0\)=0/);
  // Rows and parts read units only through that rule.
  for (const name of ['app_private.usage_operations', 'app_private.usage_parts']) {
    const body = fn(name).replace(/app_private\.usage_reported\(p\.state,p\.actual_units\)/g, '').replace(/case when r\.reported then p\.actual_units else '\{\}'::jsonb end/g, '');
    assert.doesNotMatch(body, /actual_units/, name);
  }
  // Added, never renamed: the flags the clients already read, and the counts of what isn't reported.
  const rpc = fn('public.v1_ai_usage');
  for (const key of ['input_tokens', 'cached_tokens', 'cache_write_tokens', 'output_tokens', 'searches', 'audio_ms', 'estimated', 'pending', 'unreported_calls', 'unreported_operations'])
    assert.match(rpc, new RegExp(`'${key}'`), key);
  assert.match(fn('app_private.usage_parts'), /'unreported_calls'/);
});
