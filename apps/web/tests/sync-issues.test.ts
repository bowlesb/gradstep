// Sync failures read by code (sync audit 2026-10-14, item 2): the reader learns what stopped, never server text.
import { describe, expect, it } from 'vitest';
import { BackendError } from '../src/lib/backend';
import { syncIssueText } from '../src/lib/history';

describe('sync issue copy', () => {
  it('names the update, storage, transfer, rate and key cases and keeps a generic line otherwise', () => {
    expect(syncIssueText(new BackendError('sync_page_too_large'))).toMatch(/latest Gradstep/);
    expect(syncIssueText(new BackendError('reader_update_required'))).toBe(syncIssueText(new BackendError('sync_page_too_large')));
    expect(syncIssueText(new BackendError('sync_account_storage_limit'))).toMatch(/storage is full/);
    expect(syncIssueText(new BackendError('sync_environment_transfer_limit'))).toMatch(/downloads are paused/);
    expect(syncIssueText(new BackendError('request_rate_limit'))).toMatch(/limited for a moment/);
    expect(syncIssueText(new BackendError('stale_key_epoch'))).toMatch(/encryption keys/);
    expect(syncIssueText(new BackendError('history_capacity'))).toMatch(/iPhone, iPad or Mac/);
    expect(syncIssueText(new BackendError('connection'))).toMatch(/reach Gradstep/);
    expect(syncIssueText(new Error('server said: secret detail'))).toBe('Your chat history couldn’t be synced. Reload the page to try again.');
    expect(syncIssueText(new BackendError('something_new'))).not.toContain('something_new');
  });
});
