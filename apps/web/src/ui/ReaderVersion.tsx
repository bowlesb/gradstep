// The paper's ⋯ › Reader version details (docs/architecture/READER_VERSIONS.md; owner, build 62: "a message you can
// access… the version reader number for this paper, the current version, and if it's more, the option to update it. We
// don't need to interrupt an otherwise working reader experience"), as the apps' ReaderVersionSheet. This browser
// prepares a paper afresh each time it opens, so its copy is normally this browser's version; an older one (a copy kept
// from before) offers Update this paper, which prepares it again while the current copy stays on screen.
import type { VerifiedBundle } from '../lib/bundle';
import { bundleRevision, changesSince, CURRENT_READER } from '../lib/reader-versions';
import { Dialog, SheetTop } from './common';
import { Icon } from './icons';

export interface ReaderUpdate { running: boolean; updated?: boolean; failure?: string; code?: string }

export function ReaderVersionDialog({ bundle, update, onUpdate, onClose }: {
  bundle: VerifiedBundle | null; update: ReaderUpdate | null; onUpdate: () => void; onClose: () => void;
}) {
  const shown = bundle ? bundleRevision(bundle) : null;
  const outdated = !!bundle && (shown === null || shown < CURRENT_READER.revision);
  return <Dialog open onClose={onClose} title="Reader version" className="reader-version-dialog">
    <div className="reader-version" data-testid="reader-version">
      <SheetTop onClose={onClose} testID="reader-version-close"><h2>Reader version</h2></SheetTop>
      <dl className="reader-version-facts">
        <div><dt>This paper</dt><dd data-testid="reader-version-paper">{!bundle ? 'Not prepared yet' : shown !== null ? `Version ${shown}` : 'An earlier version'}</dd></div>
        <div><dt>This browser</dt><dd data-testid="reader-version-browser">Version {CURRENT_READER.revision}</dd></div>
      </dl>
      <p className="fine">Each paper is prepared in this browser from arXiv’s web version. Updating prepares it again with this browser’s reader.</p>
      {outdated ? <>
        <section aria-labelledby="reader-version-new">
          <h3 id="reader-version-new">New since this paper’s version</h3>
          <ul className="reader-version-changes" data-testid="reader-version-changes">
            {changesSince(shown).map(v => <li key={v.revision}><strong>Version {v.revision}</strong><span>{v.note}</span></li>)}
          </ul>
        </section>
        <div className="reader-version-update">
          {update?.running ? <p className="fine" role="status" data-testid="reader-version-updating"><span className="spinner small" aria-hidden="true" /> Updating…</p>
            : <button className="primary" onClick={onUpdate} data-testid="reader-version-update"><Icon name="refresh" size={15} />Update this paper</button>}
          {update?.failure && <div className="reader-version-failure" role="alert" data-testid="reader-version-failure">
            <p>{update.failure}</p>{update.code && <p className="fine"><code>Code: {update.code}</code></p>}</div>}
          <p className="fine">The copy you’re reading stays until the update is ready.</p>
        </div>
      </> : bundle && <p className="reader-version-latest" data-testid="reader-version-latest"><Icon name="check" size={15} />
        {update?.updated ? 'Updated. This paper uses the latest reader.' : 'This paper uses the latest reader.'}</p>}
    </div>
  </Dialog>;
}
