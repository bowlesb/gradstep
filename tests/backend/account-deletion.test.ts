import test from 'node:test';
import assert from 'node:assert/strict';
import { allowedPrefix, completeAccountDeletion, IncompleteDeletionScan, listPrefix, sweepAccountDeletions } from '../../supabase/functions/_shared/account-deletion.ts';

const account = '17000000-0000-0000-0000-00000000000a';
function fakeService(files: Record<string, string[]>, options: { failRemoveTimes?: number; failLogin?: boolean; failFinish?: boolean; beginError?: string } = {}) {
  const removed: { bucket: string; paths: string[] }[] = [], rpcs: string[] = [], reports: Record<string, unknown>[] = [];
  let removeFailures = options.failRemoveTimes ?? 0;
  const tree = (bucket: string) => files[bucket] ?? [];
  const service = {
    storage: { from: (bucket: string) => ({
      list: async (folder: string, { limit, offset }: { limit: number; offset: number }) => {
        const children = new Set<string>();
        for (const path of tree(bucket)) if (path.startsWith(folder + '/')) children.add(path.slice(folder.length + 1).split('/')[0]);
        const entries = [...children].map(name => {
          const isFile = tree(bucket).includes(`${folder}/${name}`);
          return { name, id: isFile ? 'file' : null };
        });
        return { data: entries.slice(offset, offset + limit), error: null };
      },
      remove: async (paths: string[]) => {
        if (removeFailures > 0) { removeFailures--; return { error: { message: 'temporary' } }; }
        removed.push({ bucket, paths }); files[bucket] = tree(bucket).filter(path => !paths.includes(path)); return { error: null };
      },
    }) },
    rpc: async (name: string, params?: Record<string, unknown>) => {
      rpcs.push(name);
      if (name === 'worker_account_deletions_pending') return { error: null, data: [account] };
      if (name === 'worker_account_deletion_attempt') { reports.push(params!); return { error: null, data: {} }; }
      if (name === 'worker_delete_account_begin') return options.beginError ? { error: { message: options.beginError }, data: null }
        : { error: null, data: { objects: [], prefixes: [{ bucket: 'paper-assets', prefix: `private/${account}/` }] } };
      return { error: options.failFinish ? { message: 'down' } : null, data: 1 };
    },
    auth: { admin: { deleteUser: async () => ({ error: options.failLogin ? { message: 'internal error' } : null }) } },
  };
  return { service: service as never, removed, rpcs, reports };
}

test('lists every file under the private prefix recursively', async () => {
  const { service } = fakeService({ 'paper-assets': [`private/${account}/originals/a.pdf`, `private/${account}/reader/x/index.html`,
    `private/${account}/reader/x/assets/1.jpg`, 'private/other/originals/b.pdf', 'reader/shared/index.html'] });
  const files = await listPrefix(service, 'paper-assets', `private/${account}/`);
  assert.deepEqual(files.sort(), [`private/${account}/originals/a.pdf`, `private/${account}/reader/x/assets/1.jpg`, `private/${account}/reader/x/index.html`]);
});

test('removes listed and private files, marks them deleted, then deletes the login', async () => {
  const { service, removed, rpcs } = fakeService({ 'paper-assets': [`private/${account}/originals/a.pdf`, 'reader/shared/index.html'] }, { failRemoveTimes: 1 });
  const outcome = await completeAccountDeletion(service, account, {
    objects: [{ bucket: 'support', path: `${account}/report/shot.png` }], private_prefix: `private/${account}/` });
  assert.deepEqual(outcome, { complete: true });
  assert.deepEqual(removed.map(r => r.bucket).sort(), ['paper-assets', 'support']);
  assert.deepEqual(removed.find(r => r.bucket === 'paper-assets')!.paths, [`private/${account}/originals/a.pdf`], 'shared files are never touched');
  assert.deepEqual(rpcs, ['worker_delete_account_finish']);
});

test('a wrong prefix is ignored and failures report the step reached', async () => {
  const wrong = fakeService({ 'paper-assets': [`private/${account}/originals/a.pdf`] });
  await completeAccountDeletion(wrong.service, account, { objects: [], private_prefix: 'reader/' });
  assert.equal(wrong.removed.length, 0, 'only the account’s own private prefix is walked');
  const files = fakeService({}, { failRemoveTimes: 10 });
  assert.deepEqual(await completeAccountDeletion(files.service, account, { objects: [{ bucket: 'support', path: 'x' }] }), { complete: false, step: 'files' });
  assert.deepEqual(await completeAccountDeletion(fakeService({}, { failFinish: true }).service, account, { objects: [] }), { complete: false, step: 'finish' });
  assert.deepEqual(await completeAccountDeletion(fakeService({}, { failLogin: true }).service, account, { objects: [] }), { complete: false, step: 'login' });
});

const sha = 'a'.repeat(64);
test('only the account’s own folders and its conversions’ raw/reader folders may be emptied', () => {
  assert.ok(allowedPrefix(account, 'paper-assets', `private/${account}/`));
  // Private episodes and their device-sent text (migration 070): only this account's folders, never the shared ones.
  assert.ok(allowedPrefix(account, 'podcast-assets', `private/${account}/`));
  assert.ok(allowedPrefix(account, 'private-content', `podcast-sources/${account}/`));
  assert.ok(!allowedPrefix(account, 'podcast-assets', 'shared/') && !allowedPrefix(account, 'podcast-assets', 'private/'));
  assert.ok(!allowedPrefix(account, 'private-content', 'podcast-sources/') && !allowedPrefix(account, 'private-content', `${account}/`));
  assert.ok(allowedPrefix(account, 'paper-assets', `raw/${sha}/`) && allowedPrefix(account, 'paper-assets', `reader/${sha}/`));
  assert.ok(allowedPrefix(account, 'support', `${account}/`));
  assert.ok(allowedPrefix(account, 'paper-uploads', `${account}/`), 'PDF uploads (migration 039)');
  // Encrypted note images (migration 095): the account's own folder only.
  assert.ok(allowedPrefix(account, 'note-assets', `${account}/`));
  assert.ok(!allowedPrefix(account, 'note-assets', '') && !allowedPrefix(account, 'note-assets', 'other/') && !allowedPrefix(account, 'note-assets', `private/${account}/`));
  for (const [bucket, prefix] of [['paper-assets', 'private/other/'], ['paper-assets', 'reader/'], ['paper-assets', 'originals/'],
    ['support', 'other/'], ['paper-uploads', 'other/'], ['paper-uploads', ''], ['private-content', `${account}/`], ['paper-assets', `raw/${sha}/../`]]) {
    assert.equal(allowedPrefix(account, bucket, prefix), false, `${bucket}:${prefix}`);
  }
});

test('conversion folders are emptied and a forged prefix is ignored', async () => {
  const { service, removed } = fakeService({ 'paper-assets': [`reader/${sha}/index.html`, `reader/${sha}/manifest.json`, `raw/${sha}/output.mmd.zip`, 'reader/shared/index.html'] });
  const outcome = await completeAccountDeletion(service, account, { objects: [], prefixes: [
    { bucket: 'paper-assets', prefix: `reader/${sha}/` }, { bucket: 'paper-assets', prefix: `raw/${sha}/` }, { bucket: 'paper-assets', prefix: 'reader/' }] });
  assert.deepEqual(outcome, { complete: true });
  assert.deepEqual(removed.flatMap(r => r.paths).sort(), [`raw/${sha}/output.mmd.zip`, `reader/${sha}/index.html`, `reader/${sha}/manifest.json`]);
});

test('the worker sweep resumes pending deletions', async () => {
  const { service, rpcs } = fakeService({ 'paper-assets': [`private/${account}/originals/a.pdf`] });
  const logs: Record<string, unknown>[] = [];
  await sweepAccountDeletions(service, fields => logs.push(fields));
  // Podcast work is closed in its own committed step before deletion begins (migration 048).
  assert.deepEqual(rpcs, ['worker_account_deletions_pending', 'worker_podcast_account_closing', 'worker_delete_account_begin', 'worker_delete_account_finish',
    'worker_account_deletion_attempt']);
  assert.deepEqual(logs, [{ event: 'account_deletion_swept', account_id: account, step: undefined }]);
});

test('the sweep reports every outcome so a failing account backs off (migration 128)', async () => {
  const done = fakeService({});
  await sweepAccountDeletions(done.service, () => {});
  assert.deepEqual(done.reports, [{ p_account_id: account, p_complete: true, p_step: null, p_code: null }]);
  const busy = fakeService({}, { beginError: 'account_busy' });
  await sweepAccountDeletions(busy.service, () => {});
  assert.deepEqual(busy.reports, [{ p_account_id: account, p_complete: false, p_step: 'begin', p_code: 'account_busy' }]);
  const other = fakeService({}, { beginError: 'something private' });
  await sweepAccountDeletions(other.service, () => {});
  assert.deepEqual(other.reports, [{ p_account_id: account, p_complete: false, p_step: 'begin', p_code: 'begin_failed' }], 'a raw message is never reported');
  const finish = fakeService({}, { failFinish: true });
  await sweepAccountDeletions(finish.service, () => {});
  assert.deepEqual(finish.reports.at(-1), { p_account_id: account, p_complete: false, p_step: 'finish', p_code: null });
});

test('unknown writes block physical erasure and its completion rather than racing a late upload', async () => {
  const { service, removed, rpcs } = fakeService({ 'paper-assets': [`private/${account}/originals/a.pdf`] });
  const outcome = await completeAccountDeletion(service, account, { blocked: 'asset_write_uncertain', objects: [],
    prefixes: [{ bucket: 'paper-assets', prefix: `private/${account}/` }] });
  assert.deepEqual(outcome, { complete: false, step: 'files', code: 'asset_write_uncertain' });
  assert.equal(removed.length, 0);
  assert.equal(rpcs.length, 0);
});

test('a truncated file or folder scan never confirms erasure or releases capacity', async () => {
  for (const folders of [false, true]) {
    let listed = 0, removed = 0, finished = 0, loginDeleted = 0;
    const service = {
      storage: { from: () => ({
        list: async (_folder: string, { limit, offset }: { limit: number; offset: number }) => {
          listed++;
          return { error: null, data: Array.from({ length: Math.min(limit, 20_001 - offset) }, (_, i) =>
            ({ name: `object-${offset + i}`, id: folders ? null : 'file' })) };
        },
        remove: async () => { removed++; return { error: null }; },
      }) },
      rpc: async () => { finished++; return { error: null }; },
      auth: { admin: { deleteUser: async () => { loginDeleted++; return { error: null }; } } },
    } as never;
    await assert.rejects(() => listPrefix(service, 'paper-assets', `private/${account}/`), IncompleteDeletionScan);
    listed = 0;
    const result = await completeAccountDeletion(service, account, { private_prefix: `private/${account}/` });
    assert.deepEqual(result, { complete: false, step: 'files', code: 'deletion_scan_incomplete' });
    assert.ok(listed <= 21, 'an incomplete scan is not retried three times');
    assert.deepEqual([removed, finished, loginDeleted], [0, 0, 0]);
  }
});

test('note images: every planned object and the folder are removed, and a second listing must be empty', async () => {
  const blob = '0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a', stray = '7b0e8c1d-2a3f-4c5d-8e6f-7a8b9c0d1e2f';
  const { service, removed, rpcs } = fakeService({ 'note-assets': [`${account}/${blob}`, `${account}/${stray}`, `other/${blob}`] });
  const plan = { objects: [{ bucket: 'note-assets', path: `${account}/${blob}` }], prefixes: [{ bucket: 'note-assets', prefix: `${account}/` }] };
  assert.deepEqual(await completeAccountDeletion(service, account, plan), { complete: true });
  assert.deepEqual(removed.flatMap(r => r.paths).sort(), [`${account}/${blob}`, `${account}/${stray}`], 'an uninventoried object in the folder too; never another account');
  assert.deepEqual(rpcs, ['worker_delete_account_finish']);

  // Storage reports success but the folder still lists an object: not finished, inventory rows kept.
  const stuck = fakeService({ 'note-assets': [`${account}/${blob}`] });
  const unremoved = { ...stuck.service as object, storage: { from: (bucket: string) => ({ ...(stuck.service as never as { storage: { from(b: string): object } }).storage.from(bucket),
    remove: async () => ({ error: null }) }) } } as never;
  assert.deepEqual(await completeAccountDeletion(unremoved, account, plan), { complete: false, step: 'files', code: 'deletion_unverified' });
  assert.deepEqual(stuck.rpcs, [], 'finish (which removes the inventory rows) is not called');
});
