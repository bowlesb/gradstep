// Reader version details (docs/architecture/READER_VERSIONS.md): the browser reads the apps' list of versions, names the
// version that prepared a bundle by its build, and lists what changed since; the failure codes behind the reader's ⓘ.
import { describe, expect, it } from 'vitest';
import shipped from '../../apple/ScienceReader/Resources/arxiv-reader-build.json';
import { ArxivReaderError } from '../src/lib/arxiv-reader';
import { bundleRevision, changesSince, CURRENT_READER, READER_VERSIONS } from '../src/lib/reader-versions';

const bundle = (kind: string, renderer: string, sha: string) => ({ manifest: { source: { kind }, renderer: { id: renderer, build_sha256: sha } } }) as any;

describe('reader versions', () => {
  it('is the apps’ list, newest first, and names this browser’s compiler build', () => {
    expect(READER_VERSIONS.map(v => v.revision)).toEqual([...READER_VERSIONS.map(v => v.revision)].sort((a, b) => b - a));
    expect(CURRENT_READER).toEqual({ revision: shipped.revision, build_sha256: shipped.build_sha256, renderer_id: shipped.renderer_id });
    expect(READER_VERSIONS.find(v => v.revision === CURRENT_READER.revision)?.build_sha256).toBe(CURRENT_READER.build_sha256);
    expect(READER_VERSIONS.every(v => v.note.trim().length > 0)).toBe(true);
  });
  it('names the version that prepared a bundle by its build; another kind of bundle has none', () => {
    expect(bundleRevision(bundle('arxiv-html', CURRENT_READER.renderer_id, CURRENT_READER.build_sha256))).toBe(CURRENT_READER.revision);
    const older = READER_VERSIONS.find(v => v.revision < CURRENT_READER.revision && v.build_sha256)!;
    expect(bundleRevision(bundle('arxiv-html', CURRENT_READER.renderer_id, older.build_sha256))).toBe(older.revision);
    expect(bundleRevision(bundle('arxiv-html', CURRENT_READER.renderer_id, 'f'.repeat(64)))).toBeNull();
    expect(bundleRevision(bundle('mathpix-mmd', 'timestep-mathpix-mathml-v1', CURRENT_READER.build_sha256))).toBeNull();
  });
  it('lists what changed after a version, up to this browser’s; every version when it is unknown', () => {
    const older = CURRENT_READER.revision - 2;
    expect(changesSince(older).map(v => v.revision)).toEqual(READER_VERSIONS.filter(v => v.revision > older && v.revision <= CURRENT_READER.revision).map(v => v.revision));
    expect(changesSince(CURRENT_READER.revision)).toEqual([]);
    expect(changesSince(null)).toHaveLength(READER_VERSIONS.filter(v => v.revision <= CURRENT_READER.revision).length);
  });
});

describe('failure codes', () => {
  it('gives a short code for each way a paper can fail to open, never its text', () => {
    expect(new ArxivReaderError('arXiv is busy. Try preparing this paper again later.', 'network').code).toBe('arxiv_busy');
    expect(new ArxivReaderError('Couldn’t retrieve this paper from arXiv. Check your connection and try again.', 'network').code).toBe('retrieval');
    expect(new ArxivReaderError('arXiv couldn’t make a web version of this paper, which the reader needs. Its PDF opens from arXiv in a new tab.', 'no-html').code).toBe('no_html');
    expect(new ArxivReaderError('Preparing this paper took too long.', 'prepare', 'timeout').code).toBe('timeout');
    expect(new ArxivReaderError('Something the reader does not know.', 'prepare', 'arxiv_math_coverage').code).toBe('arxiv_math_coverage');
    expect(new ArxivReaderError('Something the reader does not know.').code).toBe('unknown');
    expect(new ArxivReaderError('Something else.', 'no-html').code).toBe('no_html');
  });
});
