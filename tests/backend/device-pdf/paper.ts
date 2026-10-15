// A four-page synthetic article exercising every rule of the reference converter that a real paper meets:
// running heads and page numbers on every page, a publisher strip of front matter, a title with an author block,
// a full-width abstract, two columns with a paragraph continued across them, a hyphen joined across lines,
// inline formulas, a numbered display and a picture-only display, a footnote, a figure with its caption, a table
// read as cells (a math cell, a dagger, a wrapped entry, a spanning header), a listing with a formula, an orphan
// list line no detection covers, a duplicate of the title in the text layer, a references section closed by an
// appendix heading, and two detections of one box under different classes.
import { det, extent, line, lines, page, type G } from './synthetic.ts';
import type { PageInput } from '../../../supabase/functions/_shared/reader/device-pdf/types.ts';

const L = 54, R = 315; // column lefts (points); columns are 243 pt wide
export function syntheticPaper(): PageInput[] {
  const pages: PageInput[] = [];
  const furniture = (n: number) => ({ head: line('Preprint under review at a venue', 230, 24, 8), foot: line(String(n), 302, 760, 8) });
  // Page 1
  {
    const { head, foot } = furniture(1);
    const strip = lines(['Received 1 May 2026; accepted 2 June; published 3 July.', 'Copyright the authors. Open access under CC BY.'], L, 44, 7);
    const title = line('Sparse Experts at Scale', 220, 70, 17);
    const authors = lines(['Ada Lovelace$^1$ and Alan Turing$^2$', '$^1$University of Somewhere $^2$Institute of Elsewhere'], 170, 100, 10);
    const abstractHead = line('Abstract', 284, 140, 11);
    const abstract = lines(['We study routing with $k$ experts and show that sparse models match dense ones at a', 'fraction of the cost, with a router whose load is balanced by an auxiliary loss term.'], 90, 158, 10);
    const intro = line('1 Introduction', L, 200, 12);
    const p1 = lines(['Mixture models route each token to a', 'few experts. The router computes $W x$', 'and a softmax over the experi-', 'ments that follow, and the loss of'], L, 220);
    const display = line('$y = W x + b$', 110, 272);
    const tag = line('(1)', 280, 272);
    const p2 = lines(['After the equation the text goes on.'], L, 292);
    const orphan = line('* a list item no detector saw at all', L, 312);
    const note = line('1 Code is available on the web.', L, 700, 8);
    const p3 = lines(['continued in the right column, so the', 'paragraph is one piece of the text.'], R, 220);
    const figCaption = line('Figure 1: Routing tokens to experts.', R, 420, 9);
    const p4 = lines(['A new paragraph starts here.'], R, 440);
    const glyphs: G[] = [...head, ...strip, ...title, ...authors, ...abstractHead, ...abstract, ...intro, ...p1, ...display, ...tag, ...p2,
      ...orphan, ...p3, ...figCaption, ...p4, ...note, ...foot];
    pages.push(page(glyphs, [
      det('title', extent(title), 0.95), det('paragraph', extent(strip), 0.62), det('paragraph', extent(authors.slice(0, 22)), 0.81),
      det('footnote', extent(authors.slice(22)), 0.66), det('heading', extent(abstractHead), 0.9), det('abstract', extent(abstract), 0.93),
      det('heading', extent(intro), 0.92), det('paragraph', extent(p1), 0.91), det('display', extent(display, 3), 0.88),
      det('paragraph', extent(p2), 0.9), det('paragraph', extent(p3), 0.9), det('figure', [R, 300, R + 230, 410], 0.85),
      det('caption', extent(figCaption), 0.8), det('paragraph', extent(p4), 0.89), det('footnote', extent(note), 0.7),
      det('paragraph', extent(head), 0.65), det('paragraph', extent(foot, 2), 0.61),
    ]));
  }
  // Page 2
  {
    const { head, foot } = furniture(2);
    const method = line('2 Method', L, 60, 12);
    const listing = lines(['Algorithm 1 Routing', 'for each token $t$ do', '  send it to the top $k$ experts'], L, 80, 9);
    const p1 = lines(['The method has two parts and one loss.'], L, 130);
    const tableCaption = line('Table 1: Results on the benchmark.', L, 160, 9);
    const table = [...line('Model', L, 180), ...line('Accuracy', 160, 180), ...line('Cost', 240, 180),
      ...line('Dense', L, 195), ...line('91.0', 160, 195), ...line('1.0', 240, 195),
      ...line('Sparse', L, 210), ...line('91.5^†^', 160, 210), ...line('$α$', 240, 210),
      ...line('Sparse with a long', L, 225), ...line('92.0', 160, 225), ...line('0.4', 240, 225),
      ...line('name', L, 236)];
    const details = line('2.1 Details', R, 60, 12);
    const p2 = lines(['Each expert is a small network and the', 'router is linear.'], R, 80);
    const picture = [R + 20, 120, R + 200, 150];
    const p3 = lines(['A dup of the next detection box.'], R, 170);
    const glyphs: G[] = [...head, ...method, ...listing, ...p1, ...tableCaption, ...table, ...details, ...p2, ...p3, ...foot];
    pages.push(page(glyphs, [
      det('heading', extent(method), 0.92), det('listing', extent(listing), 0.8), det('paragraph', extent(p1), 0.9),
      det('caption', extent(tableCaption), 0.83), det('table', extent(table, 2), 0.87), det('heading', extent(details), 0.9),
      det('paragraph', extent(p2), 0.9), det('display', picture, 0.7), det('paragraph', extent(p3), 0.9), det('heading', extent(p3), 0.61),
      det('paragraph', extent(head), 0.65),
    ]));
  }
  // Page 3: the title again in the text layer, references, an appendix after them
  {
    const { head, foot } = furniture(3);
    const again = line('Sparse Experts at Scale', L, 60, 10);
    const refs = line('References', L, 90, 12);
    const r1 = line('[1] A. Author. A first paper. 2020.', L, 110);
    const r2 = line('[2] B. Author. A second paper on $x$. 2021.', L, 125);
    const appendix = line('A Appendix', L, 160, 12);
    const p1 = lines(['The appendix has more of the details.'], L, 180);
    const glyphs: G[] = [...head, ...again, ...refs, ...r1, ...r2, ...appendix, ...p1, ...foot];
    pages.push(page(glyphs, [
      det('paragraph', extent(again), 0.7), det('heading', extent(refs), 0.92), det('bibitem', extent(r1), 0.9), det('bibitem', extent(r2), 0.9),
      det('heading', extent(appendix), 0.9), det('paragraph', extent(p1), 0.9), det('paragraph', extent(foot, 2), 0.61),
    ]));
  }
  // Page 4: almost empty (a stray detection with one letter) so furniture counts over four pages
  {
    const { head, foot } = furniture(4);
    const stray = line('x', 300, 400);
    pages.push(page([...head, ...stray, ...foot], [det('paragraph', extent(stray), 0.6)]));
  }
  return pages;
}
