// The agent's paper context, citations and follow-up suggestions (docs/architecture/CHAT.md, 2026-10-14).
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { SSEParser } from '../src/lib/chat';
import { renderMarkdown } from '../src/lib/markdown';
import { buildPaperContext, citedBlock, CITATION_PATTERN, PAPER_CONTEXT_FORMAT } from '../src/lib/paper-context';
import { bridgeAnchor, citationAnchor, citedMarker } from '../src/lib/passage';
import type { ReaderIndex } from '../src/lib/bundle';

const fixture = (name: string) => {
  const p = JSON.parse(readFileSync(new URL(`../../../tests/fixtures/reader-arxiv/${name}`, import.meta.url), 'utf8')) as { members: { path: string; base64: string }[] };
  return JSON.parse(Buffer.from(p.members.find(m => m.path === 'reader.json')!.base64, 'base64').toString()) as ReaderIndex;
};
const golden = (name: string) => readFileSync(new URL(`../../../tests/fixtures/reader-arxiv/${name}`, import.meta.url), 'utf8');

describe('paper context v2', () => {
  it('numbers every block in index order and matches the shared golden text byte for byte', () => {
    expect(PAPER_CONTEXT_FORMAT).toBe('reader-local-context-v2');
    expect(buildPaperContext(fixture('package.json'))).toBe(golden('local-context-v2.txt'));
    expect(buildPaperContext(fixture('figures-package.json'))).toBe(golden('figures-local-context-v2.txt'));
    const text = buildPaperContext(fixture('package.json'));
    expect(text.startsWith('[¶1] # Authored HTML fixture\n\n[¶2] A. Author\n\n[¶3] ## 1 Introduction')).toBe(true);
    expect(text).toContain('[¶5] \\[ x^2 \\]');
    expect(text).toContain('[¶6] [Figure] Figure 1: A test figure.');
    expect(text).toContain('[¶8] - First item');
    expect([...text.matchAll(CITATION_PATTERN)].map(m => Number(m[1]))).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
  });
  it('resolves cited markers to blocks and refuses ones the paper lacks', () => {
    const index = fixture('package.json');
    expect(citedBlock(index, 1)?.kind).toBe('heading'); expect(citedBlock(index, 11)?.text).toBe('[1] Author. Paper.');
    expect(citedBlock(index, 0)).toBeNull(); expect(citedBlock(index, 12)).toBeNull(); expect(citedBlock(index, 1.5)).toBeNull();
    expect(citedMarker(citationAnchor(12))).toBe(12); expect(citedMarker({ quote: 'x', prefix: '', suffix: '' })).toBeNull();
    expect(bridgeAnchor('c', citationAnchor(2), undefined, 'm', 'b-1-2')).toMatchObject({ element: '¶2', quote: '', block: 'b-1-2', same: false });
    expect(bridgeAnchor('c', { quote: 'q', prefix: '', suffix: '', manifestSHA256: 'm' }, undefined, 'm')).not.toHaveProperty('block');
  });
});

describe('citations in answers', () => {
  it('renders [¶N] as a passage control and leaves other brackets to Markdown', () => {
    const html = renderMarkdown('See [¶12] and [¶3][¶4]; not [¶] nor [¶123456] nor [12] nor [¶x].');
    expect(html).toContain('<span class="cite" data-cite="12" role="link" tabindex="0" title="Go to passage ¶12">¶12</span>');
    expect(html).toContain('data-cite="3"'); expect(html).toContain('data-cite="4"');
    expect(html).toContain('[¶]'); expect(html).toContain('[¶123456]'); expect(html).toContain('[12]'); expect(html).toContain('[¶x]');
    expect(html.match(/class="cite"/g)).toHaveLength(3);
  });
  it('keeps citations inside emphasis and lists and never inside code', () => {
    const html = renderMarkdown('**Bold [¶1]** and `code [¶2]`\n\n- item [¶3]');
    expect(html).toContain('<strong>Bold <span class="cite" data-cite="1"'); expect(html).toContain('<code>code [¶2]</code>'); expect(html).toContain('<li>item <span class="cite" data-cite="3"');
  });
});

describe('follow-up suggestions', () => {
  const frames = (text: string) => new SSEParser().consume(new TextEncoder().encode(text));
  it('parses the followups event, cleans and bounds it, and ignores unusable ones', () => {
    expect(frames('event: followups\ndata: {"questions":["  How is β chosen? ","x","What does the\\tKL term do?","One","Two","Three"]}\n\n'))
      .toEqual([{ type: 'followups', questions: ['How is β chosen?', 'What does the KL term do?', 'One'] }]);
    expect(frames('event: followups\ndata: {"questions":"none"}\n\n')).toEqual([]);
    expect(frames('event: followups\ndata: {"questions":[1,""]}\n\n')).toEqual([]);
    expect(frames('event: followups\ndata: {"questions":["' + 'q'.repeat(121) + '"]}\n\n')).toEqual([]);
  });
});
