// The reader bridge's pure sections (apps/apple/ScienceReader/Resources/reader-bridge.js), evaluated unchanged as
// scripts/citation-harness.mjs does: author–year citations (CITATION MATCHER) and figure, table and algorithm
// references (FIGURE REFERENCES). The page-level behavior is covered by PaperWebViewTests in the app.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const bridge = readFileSync(new URL('../../apps/apple/ScienceReader/Resources/reader-bridge.js', import.meta.url), 'utf8');
const section = (name: string) => {
  const match = new RegExp(`// BEGIN ${name}\\n([\\s\\S]*?)// END ${name}`).exec(bridge);
  assert.ok(match, `the bridge has a ${name} section`);
  return match[1];
};
type Link = { start: number; end: number; entry?: { id: string } | null; status?: string; kind?: string; number?: string; label?: string };
const Citations = new Function(`${section('CITATION MATCHER')}\nreturn CitationMatcher;`)() as {
  parseEntry: (text: string) => ({ id?: string } & Record<string, unknown>) | null;
  index: (entries: unknown[]) => unknown;
  scan: (text: string, index: unknown) => Link[];
};
const Figures = new Function(`${section('FIGURE REFERENCES')}\nreturn FigureReferences;`)() as {
  labels: (caption: string, paragraph?: boolean) => { kind: string; number: string; primary: boolean }[];
  scan: (text: string) => Link[];
  key: (kind: string, number: string) => string;
};

// "Knows what it knows" (Li, Littman, Walsh and Strehl, Machine Learning 2011), the owner's build-21 report, in APA
// style as Springer prints it, with entries for the other forms below.
const ENTRIES = [
  'Brafman, R. I., & Tennenholtz, M. (2002). R-MAX: a general polynomial time algorithm for near-optimal reinforcement learning. JMLR, 3, 213-231.',
  'Kakade, S. M. (2003). On the sample complexity of reinforcement learning. Doctoral dissertation, University College London.',
  'Kakade, S., Kearns, M., & Langford, J. (2003). Exploration in metric state spaces. In ICML.',
  'Kearns, M. J., & Koller, D. (1999). Efficient reinforcement learning in factored MDPs. In IJCAI.',
  'Kearns, M. J., & Singh, S. P. (2002). Near-optimal reinforcement learning in polynomial time. Machine Learning, 49, 209-232.',
  'Strehl, A. L., Li, L., & Littman, M. L. (2006a). Incremental model-based learners with formal learning-time guarantees. In UAI.',
  'Strehl, A. L., Li, L., Wiewiora, E., Langford, J., & Littman, M. L. (2006b). PAC model-free reinforcement learning. In ICML.',
  'Strehl, A. L., Diuk, C., & Littman, M. L. (2007). Efficient structure learning in factored-state MDPs. In AAAI.',
  'Lopez-Paz, D., & Ranzato, M. (2017). Gradient episodic memory for continual learning. In NeurIPS.',
  'Søgaard, A., & Goldberg, Y. (2016). Deep multi-task learning with low level tasks supervised at lower layers. In ACL.',
  'César Laurent, Gabriel Pereyra, and Philémon Brakel. 2016. Batch normalized recurrent neural networks. In ICASSP.',
  'Wiewio- ra, E. (2004). Efficient exploration for reinforcement learning. Master’s thesis, University of Alberta.',
];
const index = (() => {
  const entries = ENTRIES.map((text, i) => ({ ...Citations.parseEntry(text)!, id: `ref-${i + 1}` }));
  return Citations.index(entries);
})();
const links = (text: string) => Citations.scan(text, index).map(link => `${text.slice(link.start, link.end)}>${link.entry?.id ?? link.status}`);

test('a hyphenated surname links inside a semicolon group (build 21: "Brafman and Ten-nenholtz 2002")', () => {
  assert.deepEqual(links('(Kearns and Singh 2002; Kearns and Koller 1999; Brafman and Ten-nenholtz 2002; Kakade et al. 2003; Strehl et al. 2006a, 2007)'), [
    'Kearns and Singh 2002>ref-5', 'Kearns and Koller 1999>ref-4', 'Brafman and Ten-nenholtz 2002>ref-1', 'Kakade et al. 2003>ref-3',
    'Strehl et al. 2006a>ref-6', '2007>ref-8',
  ]);
});

test('line-break, soft and Unicode hyphens, parenthetical and narrative', () => {
  assert.deepEqual(links('(Brafman and Ten- nenholtz 2002)'), ['Brafman and Ten- nenholtz 2002>ref-1']);
  assert.deepEqual(links('(Brafman and Ten-\nnenholtz 2002)'), ['Brafman and Ten-\nnenholtz 2002>ref-1']);
  assert.deepEqual(links('(Brafman and Ten­nenholtz 2002)'), ['Brafman and Ten­nenholtz 2002>ref-1']);
  assert.deepEqual(links('(Brafman and Ten‐nenholtz 2002)'), ['Brafman and Ten‐nenholtz 2002>ref-1']);
  assert.deepEqual(links('as Brafman and Ten-nenholtz (2002) showed'), ['Brafman and Ten-nenholtz (2002)>ref-1']);
  assert.deepEqual(links('Rmax (Brafman and Tennenholtz 2002)'), ['Brafman and Tennenholtz 2002>ref-1']);
  // A double-barrelled name broken at its hyphen, and one printed with a Unicode hyphen.
  assert.deepEqual(links('memory (Lopez‐Paz and Ranzato 2017; Lopez-\nPaz and Ranzato, 2017)'),
    ['Lopez‐Paz and Ranzato 2017>ref-9', 'Lopez-\nPaz and Ranzato, 2017>ref-9']);
  // The entry's own hyphenation ("Wiewio- ra").
  assert.deepEqual(links('(Wiewiora 2004)'), ['Wiewiora 2004>ref-12']);
});

test('diacritics fold on either side, including letters NFKD keeps and OCR spacing accents', () => {
  assert.deepEqual(links('(Sogaard and Goldberg, 2016; Søgaard and Goldberg 2016)'), ['Sogaard and Goldberg, 2016>ref-10', 'Søgaard and Goldberg 2016>ref-10']);
  assert.deepEqual(links('(Laurent et al., 2016; Lau- rent et al. 2016)'), ['Laurent et al., 2016>ref-11', 'Lau- rent et al. 2016>ref-11']);
});

test('a hyphen and a space before "and" or "et" is no broken name', () => {
  assert.deepEqual(links('pre- and post-training in 2002, Self- Attention 2017'), []);
});

test('caption labels: figures, tables, algorithms, the forms Mathpix prints', () => {
  const label = (caption: string, paragraph = false) => Figures.labels(caption, paragraph).map(value => Figures.key(value.kind, value.number) + (value.primary ? '' : ' (inner)'));
  assert.deepEqual(label('Figure 3: LSUN Church samples. ￼ Figure 4: LSUN Bedroom samples.'), ['figure 3', 'figure 4 (inner)']);
  assert.deepEqual(label('Fig. 2. Left: the frontier.'), ['figure 2']);
  assert.deepEqual(label('FIGURE 12a | Ablations'), ['figure 12']);
  assert.deepEqual(label('Figure A. 1: Proof sketch'), ['figure A1']);
  assert.deepEqual(label('Table 1 Parameter counts and compute'), ['table 1']);
  assert.deepEqual(label('Figure 7'), ['figure 7']);
  assert.deepEqual(label('TABLE II\nWaveform types'), ['table II']);
  assert.deepEqual(label('Algorithm 1 Training'), ['algorithm 1']);
  assert.deepEqual(label('Figure 13￼ length generalization'), ['figure 13']);
  assert.deepEqual(label('Table 5 lists the average scores'), [], 'prose, not a caption');
  assert.deepEqual(label('Figure 14: Further example attention maps as in Figure 6 (random selection).'), ['figure 14']);
  // A paragraph is a caption only with ":", "." or "|" after its label.
  assert.deepEqual(label('Table 8: Example of correct chains of thought', true), ['table 8']);
  assert.deepEqual(label('Fig. 4 shows t-SNE visualizations', true), []);
});

test('references in the text: each number its own link, lists and ranges, subfigures', () => {
  const found = (text: string) => Figures.scan(text).map(link => `${text.slice(link.start, link.end)}>${Figures.key(link.kind!, link.number!)}`);
  assert.deepEqual(found('Consider the simple navigation task in Fig. 1. There is'), ['Fig. 1>figure 1']);
  assert.deepEqual(found('as shown in Figure 3(b) and Figure 2 (right).'), ['Figure 3(b)>figure 3', 'Figure 2>figure 2']);
  assert.deepEqual(found('Figs. 2 and 3 show; Figures 2, 3, and 5 compare'), ['Figs. 2>figure 2', '3>figure 3', 'Figures 2>figure 2', '3>figure 3', '5>figure 5']);
  assert.deepEqual(found('Figures 2–4 and Tables 7-10.'), ['Figures 2>figure 2', '4>figure 4', 'Tables 7>table 7', '10>table 10']);
  assert.deepEqual(found('In Table 2, 3 runs failed.'), ['Table 2>table 2'], 'a comma after a singular word starts something else');
  assert.deepEqual(found('Algorithm 1 and Table II and figure 5'), ['Algorithm 1>algorithm 1', 'Table II>table II', 'figure 5>figure 5']);
  assert.deepEqual(found('Figure S3, Fig. A.1, Fig.1, Table~3, Figure 4 and Figures 3a–c'),
    ['Figure S3>figure S3', 'Fig. A.1>figure A1', 'Fig.1>figure 1', 'Table~3>table 3', 'Figure 4>figure 4', 'Figures 3a–c>figure 3']);
  assert.deepEqual(found('In 2019 Table 2019 shows'), [], 'no four-digit numbers');
  assert.deepEqual(found('Figure 3-right'), ['Figure 3>figure 3']);
});

const Named = new Function(`${section('NAMED REFERENCES')}\nreturn NamedReferences;`)() as { start: (before: string, link: string) => number };

test('a link over only the number takes its name too (build 71: "the entire Figure 1 should be a link")', () => {
  const named = (before: string, link: string) => { const at = Named.start(before, link); return at < 0 ? null : before.slice(at) + link; };
  assert.equal(named('as shown in Figure ', '1'), 'Figure 1');
  assert.equal(named('see Fig. ', '3'), 'Fig. 3');
  assert.equal(named('see Fig ', '3'), 'Fig 3', 'no dot');
  assert.equal(named('results in Tab.', '4'), 'Tab.4');
  assert.equal(named('from Eq. (', '2'), 'Eq. (2');
  assert.equal(named('as discussed in Sec. ', '2.2'), 'Sec. 2.2', 'the build-71 "Sec.2.2"');
  assert.equal(named('as discussed in Sec.', '2.2'), 'Sec.2.2');
  assert.equal(named('Section ', '4'), 'Section 4');
  assert.equal(named('Sections ', '3'), 'Sections 3');
  assert.equal(named('details in §', '5'), '§5');
  assert.equal(named('details in Appendix ', 'A'), 'Appendix A', 'an appendix letter');
  assert.equal(named('details in Appendix ', 'B.2'), 'Appendix B.2');
  assert.equal(named('by Lemma ', '3'), 'Lemma 3');
  assert.equal(named('by Theorem ', 'II'), 'Theorem II');
  assert.equal(named('by Thm. ', '1'), 'Thm. 1');
  assert.equal(named('see Alg. ', '1'), 'Alg. 1');
  assert.equal(named('Prop. ', '2'), 'Prop. 2');
  // Not names: other words, a word ending in a name, or a link that already says more than a number.
  assert.equal(named('reference ', '5'), null);
  assert.equal(named('Subtables ', '2'), null, 'a word ending in "tables"');
  assert.equal(named('see the ', 'A'), null);
  assert.equal(named('Section ', 'Section 4'), null);
  assert.equal(named('in Appendix ', 'Additional results'), null);
  assert.equal(named('as app ', '3'), null, 'App needs its dot');
});
