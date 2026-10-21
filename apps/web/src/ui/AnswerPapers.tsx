// "Papers in this answer" (B2; ChatRichTextView's paper list on iPhone, iPad and Mac): the arXiv IDs and DOIs a finished
// answer names, each with its page (the chat's own Open link check), Library when it is already there, else Add to
// library, which adds it as the Add paper dialog does. Detection is on this device (lib/paper-mentions.ts).
import { memo, useMemo, useState } from 'react';
import { BackendError } from '../lib/backend';
import { paperMentions, type PaperMention } from '../lib/paper-mentions';
import { Icon } from './icons';

export interface AnswerPapers {
  /** Whether this arXiv paper (version-less source ID) is in the library: a paper or a visible import. */
  has(sourceID: string): boolean;
  /** The library's title for it, when the answer gives none. */
  title(sourceID: string): string | null;
  /** Reads the saved paper, or shows its import in the Library. */
  open(sourceID: string): void;
  addArxiv(sourceID: string, revision: number | null): Promise<unknown>;
  /** The free reference lookup the reader's bibliography uses (add-reference). */
  addReference(doi: string, operationID: string): Promise<{ status?: unknown; paper?: { title?: unknown } }>;
}
type Notice = { kind: 'working' | 'added' | 'present' | 'failed' | 'other'; message: string; operationID?: string };

export const PapersInAnswer = memo(function PapersInAnswer({ text, papers }: { text: string; papers: AnswerPapers }) {
  const mentions = useMemo(() => paperMentions(text), [text]);
  const [notices, setNotices] = useState<Map<string, Notice>>(new Map());
  if (!mentions.length) return null;
  const note = (id: string, notice: Notice) => setNotices(m => new Map(m).set(id, notice));
  const add = async (mention: PaperMention) => {
    const previous = notices.get(mention.id);
    note(mention.id, { kind: 'working', message: 'Adding to your library…' });
    if (mention.kind === 'arxiv') {
      try { await papers.addArxiv(mention.arxiv!.sourceID, mention.arxiv!.revision); note(mention.id, { kind: 'added', message: 'Added. It’s being prepared to read.' }); }
      catch (error) {
        note(mention.id, error instanceof BackendError && error.code === 'library_command_pending' ? { kind: 'other', message: 'This paper already has a pending change.' }
          : { kind: 'failed', message: 'Couldn’t add it right now.' });
      }
      return;
    }
    // A retry keeps its operation, so a lost reply can't add the paper twice.
    const operationID = previous?.operationID ?? crypto.randomUUID();
    try {
      const result = await papers.addReference(mention.doi!, operationID);
      const title = typeof result.paper?.title === 'string' && result.paper.title.length <= 1_000 ? `“${result.paper.title}”` : 'This paper';
      const status = typeof result.status === 'string' ? result.status : '';
      const messages: Record<string, Notice> = {
        added: { kind: 'added', message: `Added ${title}. It’s being prepared to read.` }, present: { kind: 'present', message: `${title} is already in your library.` },
        closed: { kind: 'other', message: `${title} isn’t openly available, so it can’t be added.` }, not_found: { kind: 'other', message: 'Couldn’t identify this reference.' },
        needs_update: { kind: 'other', message: `${title} needs the latest version of Gradstep.` },
      };
      note(mention.id, Object.hasOwn(messages, status) ? messages[status] : { kind: 'failed', message: 'Couldn’t add it right now.', operationID });
    } catch { note(mention.id, { kind: 'failed', message: 'Couldn’t add it right now.', operationID }); }
  };
  return <section className="answer-papers" aria-label="Papers in this answer" data-testid="answer-papers">
    <p className="answer-papers-heading">Papers in this answer</p>
    <ol>{mentions.map((mention, i) => {
      const sourceID = mention.arxiv?.sourceID, saved = !!sourceID && papers.has(sourceID), notice = notices.get(mention.id);
      const title = mention.title ?? (sourceID ? papers.title(sourceID) : null);
      const link = <a href={mention.url} target="_blank" rel="noopener noreferrer" className="answer-paper-id">{mention.label}<Icon name="external" size={11} /></a>;
      return <li key={mention.id} className="answer-paper" data-testid="answer-paper">
        <span className="answer-paper-number" aria-hidden="true">{i + 1}.</span>
        <div className="answer-paper-body">
          {title ? <span className="answer-paper-title">{title}</span> : null}
          <span className="answer-paper-details">{link}
            {saved && <button type="button" className="link small" aria-label="Open in Library" title="Reads the saved paper, or shows its import progress" onClick={() => papers.open(sourceID!)}>
              <Icon name="book" size={12} /> Library</button>}
            {!saved && !['working', 'added', 'present'].includes(notice?.kind ?? '') && <button type="button" className="link small" aria-label={`Add ${mention.label} to library`}
              onClick={() => void add(mention)} data-testid="answer-paper-add"><Icon name="plus" size={12} /> Add to library</button>}
          </span>
          {notice && <span className="fine answer-paper-notice" role="status">{notice.kind === 'working' && <span className="spinner small" aria-hidden="true" />}{notice.message}
            {notice.kind === 'failed' && <button type="button" className="link small" onClick={() => void add(mention)}>Try again</button>}</span>}
        </div>
      </li>;
    })}</ol>
  </section>;
});
