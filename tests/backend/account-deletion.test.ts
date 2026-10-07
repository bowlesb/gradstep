import test from 'node:test';
import assert from 'node:assert/strict';
import { allowedPrefix, completeAccountDeletion, listPrefix, sweepAccountDeletions } from '../../supabase/functions/_shared/account-deletion.ts';

const account = '17000000-0000-0000-0000-00000000000a';
function fakeService(files: Record<string, string[]>, options: { failRemoveTimes?: number; failLogin?: boolean; failFinish?: boolean } = {}) {
  const removed: { bucket: string; paths: string[] }[] = [], rpcs: string[] = [];
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
        removed.push({ bucket, paths }); return { error: null };
      },
    }) },
    rpc: async (name: string) => {
      rpcs.push(name);
      if (name === 'worker_account_deletions_pending') return { error: null, data: [account] };
      if (name === 'worker_delete_account_begin') return { error: null, data: { objects: [], prefixes: [{ bucket: 'paper-assets', prefix: `private/${account}/` }] } };
      return { error: options.failFinish ? { message: 'down' } : null, data: 1 };
    },
    auth: { admin: { deleteUser: async () => ({ error: options.failLogin ? { message: 'internal error' } : null }) } },
  };
  return { service: service as never, removed, rpcs };
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
  assert.ok(allowedPrefix(account, 'paper-assets', `raw/${sha}/`) && allowedPrefix(account, 'paper-assets', `reader/${sha}/`));
  assert.ok(allowedPrefix(account, 'support', `${account}/`));
  assert.ok(allowedPrefix(account, 'paper-uploads', `${account}/`), 'PDF uploads (migration 031)');
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
  assert.deepEqual(rpcs, ['worker_account_deletions_pending', 'worker_delete_account_begin', 'worker_delete_account_finish']);
  assert.deepEqual(logs, [{ event: 'account_deletion_swept', account_id: account, step: undefined }]);
});
