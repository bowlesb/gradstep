import {it,expect} from 'vitest';
import {parsePublicPaperLink,paperShareLinks} from '../src/lib/public-paper-link';
it('public links preserve a revision and reject untrusted hosts, credentials and query data',()=>{
  expect(parsePublicPaperLink('https://app.gradstep.ai/p/arxiv/2305.18290v3')).toEqual({kind:'arxiv',identity:'2305.18290v3'});
  expect(parsePublicPaperLink('/p/arxiv/hep-th%2F9711200v1')).toEqual({kind:'arxiv',identity:'hep-th/9711200v1'});
  for(const raw of ['https://evil.test/p/arxiv/2305.18290','https://app.gradstep.ai@evil.test/p/arxiv/2305.18290','https://app.gradstep.ai/p/arxiv/2305.18290?token=x','/p/arxiv/bad'])expect(parsePublicPaperLink(raw)).toBeNull();
});
