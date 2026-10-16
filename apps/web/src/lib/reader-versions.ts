// Reader versions (docs/architecture/READER_VERSIONS.md): which version of the arXiv reader prepared a paper, this
// browser's, and what changed since — for the reader's ⋯ › Reader version details (owner, build 62: "the version reader
// number for this paper, the current version, and if it's more, the option to update it"). One list for every surface:
// the apps' resources, which the compiler build checks (scripts/build-arxiv-compiler.mjs).
import list from '../../../apple/ScienceReader/Resources/reader-versions.json';
import shipped from '../../../apple/ScienceReader/Resources/arxiv-reader-build.json';
import type { VerifiedBundle } from './bundle';

export interface ReaderVersion { revision: number; date: string; build_sha256: string; note: string }

/** Every version, newest first. */
export const READER_VERSIONS: readonly ReaderVersion[] = Object.freeze([...(list.versions as ReaderVersion[])].sort((a, b) => b.revision - a.revision));
/** The reader this browser runs (the same compiler build as the apps': public/arxiv-reader.js). */
export const CURRENT_READER: Readonly<{ revision: number; build_sha256: string; renderer_id: string }> =
  Object.freeze({ revision: shipped.revision, build_sha256: shipped.build_sha256, renderer_id: shipped.renderer_id });

/** The version that prepared an arXiv HTML bundle; null for another kind of bundle or a build not in the list. */
export function bundleRevision(bundle: Pick<VerifiedBundle, 'manifest'>): number | null {
  const { manifest } = bundle;
  if (manifest.source.kind !== 'arxiv-html' || manifest.renderer.id !== CURRENT_READER.renderer_id) return null;
  if (manifest.renderer.build_sha256 === CURRENT_READER.build_sha256) return CURRENT_READER.revision;
  return READER_VERSIONS.find(v => v.build_sha256 === manifest.renderer.build_sha256)?.revision ?? null;
}

/** What changed after `revision`, newest first, up to this browser's version; every version when it is unknown. */
export function changesSince(revision: number | null): ReaderVersion[] {
  return READER_VERSIONS.filter(v => v.revision <= CURRENT_READER.revision && (revision === null || v.revision > revision));
}
