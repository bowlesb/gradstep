import test from 'node:test';
import assert from 'node:assert/strict';
import { joinPageSplits } from '../../supabase/functions/_shared/reader/flow.ts';

test('a sentence split by a page break is joined', () => {
  assert.equal(joinPageSplits('A property is\n\\pagebreak\n\ncalled linear time invariance (LTI).\n\nNext.'),
    'A property is called linear time invariance (LTI).\n\nNext.');
  // A word hyphenated across the break keeps its hyphen and no space.
  assert.equal(joinPageSplits('Transformer lan-\n\\pagebreak\n\nguage models.'), 'Transformer lan-guage models.');
});

test('a float at the top of the next page moves after the joined paragraph', () => {
  const source = 'audio\n\\pagebreak\n\n\n\\begin{figure}\n\\includegraphics{x.jpg}\n\\caption{Figure 10: Ablations.}\n\\end{figure}\nis uniformly sampled.\nMore of it.\n\nHowever, next.';
  assert.equal(joinPageSplits(source),
    'audio is uniformly sampled.\nMore of it.\n\n\\begin{figure}\n\\includegraphics{x.jpg}\n\\caption{Figure 10: Ablations.}\n\\end{figure}\n\nHowever, next.');
});

test('complete sentences, display math, commands and capitalized continuations are left alone', () => {
  for (const source of [
    'A full sentence.\n\\pagebreak\n\ncontinues lower.',
    'Ends with a colon:\n\\pagebreak\n\nwhere x is small.',
    '\\[ x = 1 \\]\n\\pagebreak\n\nwhere x is small.',
    '\\section*{Intro}\n\\pagebreak\n\nlower text',
    'a & b \\\\\n\\pagebreak\n\nc & d',
    'no break here\n\nlower text continues',
    'stops mid sentence\n\\pagebreak\n\nThe next page starts a sentence.',
    'stops mid sentence\n\\pagebreak\n\n\\(x\\) starts with math',
    'stops mid sentence\n\\pagebreak\n\n\\begin{figure}\n\\includegraphics{x.jpg}\nnever closed',
  ]) assert.equal(joinPageSplits(source), source, source);
});

test('page footnotes between the halves move after the joined paragraph', () => {
  const source = 'trained with reinforcement learning (RL),\n\n\\footnotetext{\n*Equal contribution.\n}\n\\pagebreak\n\n\n\\begin{figure}\n\\includegraphics{f.jpg}\n\\end{figure}\nwe will show it.\n\nNext.';
  assert.equal(joinPageSplits(source),
    'trained with reinforcement learning (RL), we will show it.\n\n\\footnotetext{\n*Equal contribution.\n}\n\n\\begin{figure}\n\\includegraphics{f.jpg}\n\\end{figure}\n\nNext.');
  // A figure at the bottom of the first page is skipped too, keeping order.
  const bottom = 'existing techniques\n\n\\begin{figure}\n\\caption{Figure 1}\n\\end{figure}\n\n\\footnotetext{\nNote.\n}\n\\pagebreak\n\noften introduce latency.';
  assert.equal(joinPageSplits(bottom),
    'existing techniques often introduce latency.\n\n\\begin{figure}\n\\caption{Figure 1}\n\\end{figure}\n\n\\footnotetext{\nNote.\n}');
  // A footnote whose block never opens is not skipped.
  const unopened = 'mid sentence\n}\n\\pagebreak\n\nlower text';
  assert.equal(joinPageSplits(unopened), unopened);
});

test('a paragraph spanning several pages joins every break', () => {
  assert.equal(joinPageSplits('one\n\\pagebreak\n\ntwo\n\\pagebreak\n\nthree.'), 'one two three.');
});

test('a paragraph over three pages with a page-one footnote joins both breaks', () => {
  const source = 'One starts here and\n\n\\footnotetext{\nA note.\n}\n\\pagebreak\n\ncontinues on page two and\n\\pagebreak\n\nends on page three.\n\nNext.';
  assert.equal(joinPageSplits(source),
    'One starts here and continues on page two and ends on page three.\n\n\\footnotetext{\nA note.\n}\n\nNext.');
});

test('one-line floats are recognized on either side of the break', () => {
  assert.equal(joinPageSplits('stops mid\n\\pagebreak\n\n\\begin{figure}\\includegraphics{a.jpg}\\end{figure}\nand continues.\n\nLater paragraph.'),
    'stops mid and continues.\n\n\\begin{figure}\\includegraphics{a.jpg}\\end{figure}\n\nLater paragraph.');
  assert.equal(joinPageSplits('stops mid\n\n\\begin{table}\\caption{T}\\end{table}\n\\pagebreak\n\nand continues.'),
    'stops mid and continues.\n\n\\begin{table}\\caption{T}\\end{table}');
});

test('pathological lines stay fast', () => {
  const started = performance.now();
  joinPageSplits('word' + ' '.repeat(40_000) + '\n\\pagebreak\n\nnext line');
  joinPageSplits(('x'.repeat(200) + '\n\\pagebreak\n\n').repeat(2_000));
  assert.ok(performance.now() - started < 500, `took ${performance.now() - started} ms`);
});
