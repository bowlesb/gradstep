// arXiv identity parsing (docs/architecture/ARXIV_DEVICE_ONLY.md: our servers never contact arXiv; they only recognize
// identifiers and build the links people follow).
import test from 'node:test';
import assert from 'node:assert/strict';
import { arxivAbstractURL, arxivReference } from '../../supabase/functions/_shared/arxiv.ts';

test('arXiv references pin requested versions and normalize supported link and historical aliases', () => {
  for (const input of ['1706.03762v2', ' arXiv:1706.03762v2 ', 'https://arxiv.org/abs/1706.03762v2', 'https://arxiv.org:443/abs/1706.03762v2', 'http://export.arxiv.org/pdf/1706.03762v2.pdf?download=1#page=3']) {
    assert.deepEqual(arxivReference(input), { sourceID: '1706.03762', revision: 2 });
  }
  assert.deepEqual(arxivReference('arXiv:math.CA/0611800v2'), { sourceID: 'math/0611800', revision: 2 });
  assert.deepEqual(arxivReference('hep-th/9901001'), { sourceID: 'hep-th/9901001', revision: null });
  assert.deepEqual(arxivReference('0704.0001'), { sourceID: '0704.0001', revision: null });
  assert.deepEqual(arxivReference('1501.00001'), { sourceID: '1501.00001', revision: null });
});

test('arXiv normalization rejects malformed identifiers, other origins, credentials, ports and path encodings', () => {
  for (const value of ['1700.03762', '1713.03762', '1706.3762', '0703.0001', '1412.00001', '1501.0001', '1706.00000',
    'hep-th/0712001', 'hep-th/9101001', 'hep-th/8801001', 'hep-th/9901000', 'math.evil/0301001',
    '1706.03762v0', '1706.03762v01', '1706.03762v2147483648', '1706.03762vv2', '1706.03762\nmalicious',
    'https://arxiv.org.evil.test/abs/1706.03762', 'https://evil.test/arxiv.org/abs/1706.03762',
    'https://arxiv.org@evil.test/abs/1706.03762', 'https://name:secret@arxiv.org/abs/1706.03762',
    'https://arxiv.org:8080/abs/1706.03762', 'file:///abs/1706.03762',
    'https://arxiv.org/abs/1706%2e03762', 'https://arxiv.org/search/1706.03762',
    'https://arxiv.org/abs/%2e%2e/abs/1706.03762', 'https://arxiv.org/abs/../abs/1706.03762',
    'https://arxiv.org/abs/1706.03762/extra', 'https://arxiv.org\\@evil.test/abs/1706.03762',
    'a'.repeat(129) + '/9901001']) {
    assert.throws(() => arxivReference(value), /invalid_arxiv_id/, value);
  }
});

test('the abstract link is derived from a validated identity; query and fragment input cannot propagate', () => {
  assert.equal(arxivAbstractURL(arxivReference('https://arxiv.org/pdf/1706.03762v2.pdf?token=discard#page=3')), 'https://arxiv.org/abs/1706.03762v2');
  assert.equal(arxivAbstractURL(arxivReference('1706.03762')), 'https://arxiv.org/abs/1706.03762');
  assert.equal(arxivAbstractURL(arxivReference('arXiv:math.CA/0611800v2')), 'https://arxiv.org/abs/math/0611800v2');
  assert.throws(() => arxivAbstractURL({ sourceID: '//evil.test/path', revision: 1 }), /invalid_arxiv_id/);
  assert.throws(() => arxivAbstractURL({ sourceID: '1706.03762', revision: 0 }), /invalid_arxiv_id/);
});
