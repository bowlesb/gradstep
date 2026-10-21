import { describe, expect, it } from 'vitest';
import { ArxivReaderError } from '../src/lib/arxiv-reader';
import { failureText as message } from '../src/lib/chat';
import { preparationIssue } from '../src/lib/chat-session';

// Build 78 ("Got this error somehow?"): a question about a paper this browser couldn't prepare says why, never "open it
// first" (asking already prepares it).
describe('a question whose paper could not be prepared', () => {
  it('says why, and never asks the reader to open the paper first', () => {
    expect(preparationIssue(new ArxivReaderError('No HTML', 'no-html'))).toBe('reader_no_html');
    expect(preparationIssue(new ArxivReaderError('Offline', 'network'))).toBe('reader_retrieval');
    expect(preparationIssue(new ArxivReaderError('Compiler', 'prepare'))).toBe('reader_unprepared');
    expect(preparationIssue(new Error('local_reader_unavailable'))).toBe('local_reader_unavailable');
    for (const code of ['reader_no_html', 'reader_retrieval', 'reader_unprepared', 'local_reader_unavailable']) {
      expect(message(code)).not.toMatch(/Open this paper/);
      expect(message(code)).not.toBe('The answer couldn’t be completed. Try again.');
    }
  });
});
