// arXiv identity: what a reader typed or a page names, parsed into an identifier and version. Our servers never
// contact arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md, owner 2026-10-15): this module only recognizes input and
// builds the links people follow. Catalog records come from DataCite (datacite.ts); the device reads arXiv itself.
/** A malformed identifier (`invalid_arxiv_id`): the input names no arXiv paper. */
export class SourceError extends Error {
  readonly code: string;
  constructor(code: string) { super(code); this.code = code; }
}

const allowedInputHosts = new Set(['arxiv.org', 'www.arxiv.org', 'export.arxiv.org']); // egress-ok: parse

export interface ArxivReference { sourceID: string; revision: number | null }

function revisionNumber(value: string): number {
  if (!/^[1-9][0-9]{0,9}$/.test(value) || Number(value) > 2_147_483_647) throw new SourceError('invalid_arxiv_id');
  return Number(value);
}

// Input URLs are parsed only for identity; they are never fetched. URL credentials, nonstandard ports, arbitrary hosts/paths
// and encoded path syntax are refused, including before URL normalization.
export function arxivReference(input: string): ArxivReference {
  if (typeof input !== 'string' || input.length > 2048) throw new SourceError('invalid_arxiv_id');
  let value = input.trim();
  if (/\p{Cc}/u.test(value) || value.includes('\\')) throw new SourceError('invalid_arxiv_id');
  if (/^https?:\/\//i.test(value)) {
    const rawPath = /^https?:\/\/[^/?#]+([^?#]*)/i.exec(value)?.[1];
    if (!rawPath || /%/.test(rawPath) || /\/(?:\.|\.\.)(?:\/|$)/.test(rawPath)) throw new SourceError('invalid_arxiv_id');
    let url: URL;
    try { url = new URL(value); } catch { throw new SourceError('invalid_arxiv_id'); }
    if (!allowedInputHosts.has(url.hostname) || url.username || url.password || url.port || /%/.test(url.pathname)) throw new SourceError('invalid_arxiv_id');
    const path = /^\/(abs|pdf)\/(.+)$/.exec(url.pathname);
    if (!path) throw new SourceError('invalid_arxiv_id');
    value = path[2];
    if (path[1] === 'pdf') value = value.replace(/\.pdf$/i, '');
  } else value = value.replace(/^arxiv:\s*/i, '');
  let revision: number | null = null;
  const versioned = /^(.*)v([0-9]+)$/i.exec(value);
  if (versioned) { value = versioned[1]; revision = revisionNumber(versioned[2]); }
  const modern = /^([0-9]{2})([0-9]{2})\.([0-9]{4,5})$/.exec(value);
  if (modern) {
    const year = Number(modern[1]), month = Number(modern[2]), serial = modern[3];
    if (month < 1 || month > 12 || year < 7 || (year === 7 && month < 4) || !Number(serial) || serial.length !== (year < 15 ? 4 : 5)) throw new SourceError('invalid_arxiv_id');
  } else {
    const historic = /^([a-z][a-z0-9-]*)(?:\.([a-z]{2}))?\/([0-9]{2})([0-9]{2})([0-9]{3})$/i.exec(value);
    if (!historic) throw new SourceError('invalid_arxiv_id');
    const archive = historic[1].toLowerCase(), year = Number(historic[3]), month = Number(historic[4]);
    if (month < 1 || month > 12 || !Number(historic[5]) ||
        (year > 7 && year < 91) || (year === 91 && month < 7) || (year === 7 && month > 3) ||
        (historic[2] && !['math', 'cs', 'nlin', 'q-bio'].includes(archive))) throw new SourceError('invalid_arxiv_id');
    // Optional historical classification is not part of the external identity.
    value = `${archive}/${historic[3]}${historic[4]}${historic[5]}`;
  }
  // Match the durable catalog/import identity bound before making a request.
  if (value.length > 128) throw new SourceError('invalid_arxiv_id');
  return { sourceID: value, revision };
}

/** The paper's abstract page, for people to follow (a link shown in the library, never requested by a server). */
export function arxivAbstractURL(reference: ArxivReference): string {
  const ref = arxivReference(`${reference.sourceID}${reference.revision === null ? '' : `v${reference.revision}`}`);
  if (ref.sourceID !== reference.sourceID || ref.revision !== reference.revision) throw new SourceError('invalid_arxiv_id');
  return `https://arxiv.org/abs/${ref.sourceID}${ref.revision === null ? '' : `v${ref.revision}`}`; // egress-ok: link
}
