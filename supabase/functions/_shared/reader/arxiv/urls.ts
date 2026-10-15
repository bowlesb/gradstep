// The official arXiv HTML's identity and the only asset URLs a paper may reference.
import { check } from '../util.ts';

export const ARXIV_ID = /^(?:\d{4}\.\d{4,5}|[a-z][a-z.-]+(?:\.[A-Z]{2})?\/\d{7})$/;

export function arxivHTMLURL(sourceID: string, revision: number): string {
  check(ARXIV_ID.test(sourceID) && Number.isSafeInteger(revision) && revision >= 1 && revision <= 2147483647, 'arxiv_identity');
  return `https://arxiv.org/html/${sourceID}v${revision}`;
}

export function arxivAssetURL(reference: string, sourceURL: string): string {
  let url: URL;
  try { url = new URL(reference, sourceURL); } catch { throw new Error('arxiv_asset_url'); }
  const source = new URL(sourceURL);
  const root = source.pathname + '/';
  check(url.origin === 'https://arxiv.org' && source.origin === url.origin && !url.username && !url.password &&
    !url.port && !url.search && !url.hash && url.pathname.startsWith(root) && !/%/.test(url.pathname) &&
    /\.(?:png|jpe?g|svg)$/i.test(url.pathname) && url.href.length <= 2048, 'arxiv_asset_url');
  return url.href;
}
