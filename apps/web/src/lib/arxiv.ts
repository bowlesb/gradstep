// arXiv identity from pasted text — a port of ScienceReaderCore/ArxivReference.swift.
// A paper identity, never an address to fetch; the backend receives canonical fields only.

export interface ArxivReference { sourceID: string; revision: number | null }

// ECMAScript trim's characters, as the backend uses (C1 controls are not stripped before validation).

export function parseArxiv(input: string): ArxivReference | null {
  if (input.length > 2048) return null;
  let value = input.trim();
  if (/[\u0000-\u001f\u007f-\u009f]/.test(value) || value.includes('\\')) return null;
  if (/^https?:\/\//i.test(value)) {
    const parts = /^https?:\/\/[^/?#]+([^?#]*)/i.exec(value);
    const path = parts?.[1];
    if (!path || path.includes('%') || /\/(?:\.|\.\.)(?:\/|$)/.test(path)) return null;
    let url: URL;
    try { url = new URL(value); } catch { return null; }
    const defaultPort = url.port === '' || url.port === (url.protocol === 'https:' ? '443' : '80');
    if (!['arxiv.org', 'www.arxiv.org', 'export.arxiv.org'].includes(url.hostname.toLowerCase()) || url.username || url.password || !defaultPort) return null;
    const route = /^\/(abs|pdf)\/(.+)$/.exec(path);
    if (!route) return null;
    value = route[2];
    if (route[1] === 'pdf' && value.toLowerCase().endsWith('.pdf')) value = value.slice(0, -4);
  } else {
    value = value.replace(/^arxiv:\s*/i, '');
  }
  if (!/^[\x00-\x7f]*$/.test(value)) return null;
  let revision: number | null = null;
  const versioned = /^(.*)v([0-9]+)$/i.exec(value);
  if (versioned) {
    if (!/^[1-9][0-9]{0,9}$/.test(versioned[2]) || Number(versioned[2]) > 2_147_483_647) return null;
    value = versioned[1]; revision = Number(versioned[2]);
  }
  const modern = /^([0-9]{2})([0-9]{2})\.([0-9]{4,5})$/.exec(value);
  if (modern) {
    const year = Number(modern[1]), month = Number(modern[2]), serial = modern[3];
    if (month < 1 || month > 12 || year < 7 || (year === 7 && month < 4) || Number(serial) <= 0 || serial.length !== (year < 15 ? 4 : 5)) return null;
  } else {
    const historic = /^([a-z][a-z0-9-]*)(?:\.([a-z]{2}))?\/([0-9]{2})([0-9]{2})([0-9]{3})$/i.exec(value);
    if (!historic) return null;
    const archive = historic[1].toLowerCase(), year = Number(historic[3]), month = Number(historic[4]);
    if (month < 1 || month > 12 || Number(historic[5]) <= 0 || (year > 7 && year < 91) || (year === 91 && month < 7) || (year === 7 && month > 3)
      || (historic[2] !== undefined && !['math', 'cs', 'nlin', 'q-bio'].includes(archive))) return null;
    value = `${archive}/${historic[3]}${historic[4]}${historic[5]}`;
  }
  if (new TextEncoder().encode(value).length > 128) return null;
  return { sourceID: value, revision };
}
