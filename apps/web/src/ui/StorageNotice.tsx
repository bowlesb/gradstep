// What to do when another Gradstep tab updates (or asks to update) this browser's storage. Separate from unsupported
// key persistence: nothing here is a browser capability problem, and nothing reloads, upgrades or deletes by itself.
import { useSyncExternalStore } from 'react';
import { type StorageErrorCode, StorageError, storage } from '../lib/idb';

export const useStorageLifecycle = () => useSyncExternalStore(storage.subscribe, storage.snapshot);

export const NO_RELOAD_DRAFTS = 'This version of Gradstep doesn’t keep unsent drafts after a reload.';

/** Guidance for a storage error, or null when the error isn't about another tab or a cleared database. */
export function storageGuidance(error: unknown): { title: string; text: string; reload: boolean } | null {
  const code: StorageErrorCode | null = error instanceof StorageError ? error.code : null;
  switch (code) {
    case 'storage_update':
    case 'storage_upgraded':
      return { title: 'Gradstep was updated in another tab', reload: true,
        text: 'This tab can’t use this browser’s Gradstep storage any more. Copy anything you still need from your other Gradstep tabs, then reload this page.' };
    case 'storage_closed':
      return { title: 'This browser closed Gradstep’s storage', reload: true,
        text: 'Site data may have been cleared. Copy anything you still need, then reload this page.' };
    case 'storage_blocked':
      return { title: 'Waiting for another Gradstep tab', reload: false,
        text: 'An older Gradstep tab is still using this browser’s storage. Close your other Gradstep tabs to continue.' };
    default: return null;
  }
}

/** A row under the top bar. The page and its unsent text stay as they are, so they can still be read and copied. */
export function StorageNotice() {
  const { phase, issue, proposal } = useStorageLifecycle();
  if (phase !== 'open' && (issue === 'update' || issue === 'upgraded' || issue === 'closed')) {
    const closed = issue === 'closed';
    return <section className="storage-notice" role="alert" aria-labelledby="storage-notice-title" data-testid="storage-notice">
      <div className="storage-notice-text">
        <h2 id="storage-notice-title">{closed ? 'This browser closed Gradstep’s storage' : 'Gradstep was updated in another tab'}</h2>
        <p>{closed ? 'Site data may have been cleared. This tab has stopped sending and saving.' : 'This tab has stopped sending and saving so the update can finish safely.'}
          {' '}Your unsent text is still shown here: copy what you want to keep, then {closed ? 'reload this tab' : 'close this tab and continue in the updated one'}. {NO_RELOAD_DRAFTS}</p>
      </div>
      <button type="button" className="secondary small" onClick={() => location.reload()}>Reload this tab</button>
    </section>;
  }
  if (phase === 'open' && proposal) {
    return <section className="storage-notice" role="status" aria-labelledby="storage-notice-title" data-testid="storage-notice">
      <div className="storage-notice-text">
        <h2 id="storage-notice-title">Another Gradstep tab is ready to update</h2>
        <p>It’s waiting because this tab has unsent work. Send or copy it, then close this tab. {NO_RELOAD_DRAFTS}</p>
      </div>
    </section>;
  }
  if (phase === 'open' && issue === 'blocked') {
    return <section className="storage-notice" role="status" aria-labelledby="storage-notice-title" data-testid="storage-notice">
      <div className="storage-notice-text">
        <h2 id="storage-notice-title">Waiting for another Gradstep tab</h2>
        <p>An older Gradstep tab is still using this browser’s storage. Close your other Gradstep tabs to continue.</p>
      </div>
    </section>;
  }
  return null;
}
