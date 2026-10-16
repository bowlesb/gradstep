import { describe, expect, it } from 'vitest';
import { SSEParser, makeRequest, requestBody, type LocalPaperContext } from '../src/lib/chat';
import { equationKey, equationTurn, parseEquationSymbols } from '../src/lib/equation';
import { forScheme } from '../src/reader/equation-frame';

// The equation view (docs/architecture/EQUATION_VIEW.md): the server's `equation` event and the request's shape.
const event = { format: 'equation-symbols-v1', summary: 'The DPO loss.', symbols: [
  { symbol: 'β', latex: '\\beta', meaning: 'Temperature.', source: 'paper', paragraph: 2 },
  { symbol: 'σ', meaning: 'Logistic function.', source: 'general' }] };
const local: LocalPaperContext = { format: 'reader-local-context-v2', membership_id: '58000000-0000-4000-8000-000000000003', source: 'arxiv', source_id: '2601.01234',
  revision: 2, manifest_sha256: 'a'.repeat(64), source_sha256: 'b'.repeat(64), text: '[¶1] Title\n\n[¶2] L = x^2' };

describe('equation symbols', () => {
  it('keeps checked rows and drops unusable ones; a paragraph only with the paper', () => {
    expect(parseEquationSymbols(event)).toEqual(event);
    const parsed = parseEquationSymbols({ ...event, symbols: [...event.symbols, { symbol: '', meaning: 'x' }, { symbol: 'x', meaning: 'y', source: 'general', paragraph: 3 },
      { symbol: 'z', meaning: 'zed', source: 'paper', paragraph: 0 }, 'row', null] })!;
    expect(parsed.symbols.slice(2)).toEqual([{ symbol: 'x', meaning: 'y', source: 'general' }, { symbol: 'z', meaning: 'zed', source: 'general' }]);
    expect(parseEquationSymbols({ ...event, format: 'other' })).toBeNull();
    expect(parseEquationSymbols({ format: 'equation-symbols-v1', summary: '', symbols: [] })).toBeNull();
    expect(parseEquationSymbols({ ...event, symbols: Array.from({ length: 40 }, (_, i) => ({ symbol: `s${i}`, meaning: 'm', source: 'general' })) })!.symbols).toHaveLength(24);
    expect(parseEquationSymbols({ ...event, summary: 'a\u0000b ' + 'c'.repeat(700) })!.summary).toHaveLength(600);
  });
  it('arrives as a stream event; an unusable one is dropped, never fatal', () => {
    const frames = (text: string) => new SSEParser().consume(new TextEncoder().encode(text));
    expect(frames(`event: equation\ndata: ${JSON.stringify(event)}\n\n`)).toEqual([{ type: 'equation', symbols: event }]);
    expect(frames('event: equation\ndata: {"format":"x"}\n\nevent: delta\ndata: {"text":"ok"}\n\n')).toEqual([{ type: 'delta', text: 'ok' }]);
  });
});

describe('equation requests', () => {
  const turn = [{ role: 'user' as const, text: equationTurn('(7)') }];
  it('are the chat request for the paper with the action: same capabilities, no title, suggestions or figures', () => {
    const chat = makeRequest('op-1', null, [{ role: 'user', text: 'What is L?' }], 'L = x^2', null, { visualAnswers: true }); chat.localContext = local;
    for (const action of ['equation', 'equation_background'] as const) {
      const request = makeRequest('op-2', null, turn, 'L = x^2', action, { topicTitle: true, visualAnswers: true }); request.localContext = local;
      const body = requestBody(request);
      expect(body).toMatchObject({ mode: 'paper', action, consent_version: 'cloud-ai-v4', selection: { quote: 'L = x^2' }, messages: [{ role: 'user', text: 'Equation (7)' }], local_context: local });
      expect(body.capabilities).toEqual(requestBody(chat).capabilities);
      for (const key of ['topic_title', 'follow_ups', 'figures', 'document_id', 'study']) expect(body).not.toHaveProperty(key);
    }
    expect(equationTurn(null)).toBe('Equation');
    expect(equationKey('m', 'e-1', 'equation', 'sonnet-low-standard')).not.toBe(equationKey('m', 'e-1', 'equation_background', 'sonnet-low-standard'));
  });
});

it('the equation frame takes the app’s colours, whatever the system’s', () => {
  const css = ':root{color:#111}@media(prefers-color-scheme:dark){:root{color:#ddd}}@media (prefers-color-scheme: light){a{color:blue}}';
  expect(forScheme(css, 'dark')).toBe(':root{color:#111}@media(min-width: 0px){:root{color:#ddd}}@media (max-width: 0.01px){a{color:blue}}');
  expect(forScheme(css, 'light')).toBe(':root{color:#111}@media(max-width: 0.01px){:root{color:#ddd}}@media (min-width: 0px){a{color:blue}}');
});

it('a symbol is typeset from its LaTeX, else from its text read as math; an error falls back to the text', async () => {
  const { symbolMath, texFromText } = await import('../src/lib/equation-math');
  expect(texFromText('L_DPO(π_θ; π_ref)')).toBe('L_{DPO}(π_{θ}; π_{ref})');
  expect(texFromText('E_{x∼D}')).toBe('E_{x∼D}');
  expect(texFromText('x^2_i')).toBe('x^{2}_{i}');
  expect(symbolMath({ symbol: 'β', latex: '\\beta', meaning: 'm', source: 'general' })).toMatch(/^<math/);
  const text = symbolMath({ symbol: 'L_DPO(π_θ; π_ref)', meaning: 'm', source: 'general' })!;
  expect(text).toMatch(/^<math/); expect(text.match(/<msub>/g)).toHaveLength(3);
  // A bad LaTeX falls back to the text's own typesetting, and plain text without sub/superscripts stays text.
  expect(symbolMath({ symbol: 'π_θ', latex: '\\frac{', meaning: 'm', source: 'general' })).toMatch(/<msub>/);
  expect(symbolMath({ symbol: 'σ', meaning: 'm', source: 'general' })).toBeNull();
});
