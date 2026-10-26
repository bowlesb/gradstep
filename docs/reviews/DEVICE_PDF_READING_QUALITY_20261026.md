# Scientific PDFs with little mathematics — 2026-10-26

Status: port 18 verified locally. No release or deployment.
The scoped improvement is paragraph continuity; model weights and reader interactions are unchanged.

The owner asked for an independent investigation, a breakdown of product failures, measurement of the problem
and improvement, and concrete action. The existing local route uses layout detection, a contextual inline-math
tagger and a formula recognizer. Fewer equations reduce the recognizer's importance; they do not remove layout,
caption, table or text-extraction failures. This investigation found a converter state bug worth fixing before
training another model.

## Product gaps and measurement

| Subproblem | Visible failure / evidence | Appropriate measure and next approach |
|---|---|---|
| Text completeness and continuity | Sentences and words split at page breaks; columns or floats interrupt the flow. The six biology PDFs expose 60 reference-supported mid-sentence breaks. | Fixed source-boundary labels, correct joins / all new joins, missing and duplicated words per 10,000 words. **Implemented below:** preserve open-paragraph state with conservative guards. A later relation classifier could connect regions around intervening floats. |
| Journal furniture and navigation | Running titles become contents entries; footers enter paragraphs. eLife 88793 has 76 blocks containing its repeated header/footer material, including seven copies of the subject header in Contents. | Manually label margin text and real headings; measure intrusions per page and heading precision/recall. Next: repeated text plus stable geometry/font evidence. The current eight-word margin-line limit misses long headers/footers and lines combining both sides of the margin. Never remove body text merely because a string repeats. |
| Figures and captions | A caption can become ordinary body text, split across pages, or attach to the wrong image. Fourteen of 63 emitted figures in the biology set have empty captions; these are **flags to adjudicate**, not fourteen proven missing figures. | Caption-to-figure attachment precision/recall, caption-word recall, crop coverage. Label main figures, supplements, panels and continued captions separately; count only material actually printed in the PDF. A small region-relation model is a better candidate than more formula training. |
| Tables | Correct words in the wrong row/column or missing header relationships still produce misleading tables. The existing low-equation diagnostic flags 31 cell incidents. | Cell adjacency, row/column span and header association accuracy, alongside text recall. PDF-reviewed cell labels are needed; word F1 alone cannot certify a table. The added biology set has too few tables for a broad table claim. |
| Characters and scientific notation | A clean-looking PDF can yield interleaved or corrupted text; Greek letters, units, superscripts and gene names can be harmed even without display equations. PDF inspection confirms existing extraction corruption in 2610.26053 and JMLR 26-23-1578. | Character error rate on manually transcribed lines, plus exact checks of numbers, units and critical symbols. Separate native-text errors from scan/OCR errors. Consider selective local OCR only after detecting a bad text layer and measuring whether replacement improves it. |

The existing weakness explorer's counts are diagnostic leads, not an error rate. HTML float placement, citation
conventions, unmatched revisions and one-to-one block matching can all produce false incidents. A reading with
90% text F1 is not thereby “90% accurate,” particularly for tables or numbers.

## Frozen evaluation and goal

Before changing the converter, select every accepted existing reference with at most six inline-plus-display
expressions per PDF page: **13 papers / 329 pages** across arXiv and publisher PDFs. Add **six biology papers /
167 pages**, each with zero or one JATS display equation. Publisher PDF/XML URLs and byte digests, source places,
and the 60 primary boundary labels are checked in at
[`continuity-corpus.json`](../../tests/fixtures/device-pdf/continuity-corpus.json). PDFs and model records remain local.

| Publisher paper | Assigned split | Pages | Baseline mid-sentence breaks | Repaired | Remaining |
|---|---|---:|---:|---:|---:|
| [eLife 106496](https://elifesciences.org/articles/106496) | Development | 29 | 9 | 7 | 2 |
| [eLife 88793](https://elifesciences.org/articles/88793) | Development | 22 | 8 | 0 | 8 |
| [PLOS Biology 3002467](https://journals.plos.org/plosbiology/article?id=10.1371/journal.pbio.3002467) | Development | 36 | 13 | 8 | 5 |
| [eLife 89828](https://elifesciences.org/articles/89828) | Validation | 33 | 11 | 5 | 6 |
| [eLife 93855](https://elifesciences.org/articles/93855) | Validation | 25 | 13 | 10 | 3 |
| [PLOS Biology 3003934](https://journals.plos.org/plosbiology/article?id=10.1371/journal.pbio.3003934) | Validation | 22 | 6 | 4 | 2 |
| **Total** | | **167** | **60** | **34** | **26** |

The publisher files are pinned by hashes, not just a current article URL. Body paragraphs are aligned separately
from headings, captions and tables. Two reader fragments must each contain at least twelve normalized words,
have at least 90% ordered alignment to the same JATS paragraph, and have no more than three intervening reference
words to enter the primary cohort. A terminal full stop/question/exclamation mark, including closing punctuation,
excludes a boundary from the mid-sentence measure. This finds 68 candidate paragraph splits, of which 60 meet
the primary definition. It is a reproducible subset, not an exhaustive annotation of every PDF paragraph.

**Goal fixed before implementation:** reduce these mid-sentence breaks by at least 50%; introduce no incorrect
joins in reviewed changed boundaries; preserve text, math, figures/tables and all source regions. Fixing a break
requires **both original source fragments to occupy one candidate paragraph**. Re-aligning the candidate must
not make difficult examples disappear from the denominator.

The split assignments predate the fix, but the wider audit informed conservative guards. These are development
and regression-validation results, **not an untouched held-out generalization claim**. New journals and a fresh
held-out set are required for a subsequent learned relation model. There is no model training in this change.

## Implementation

`convert.ts` kept the pending paragraph across pages but reset `prevCls` inside each page loop. The existing
continuation predicate therefore always failed at a page boundary. Port 18 keeps the state across adjacent pages.

A new join requires unfinished prose, a lowercase/parenthesized/formula-led continuation under the existing
start rule, at least three prose words in each fragment, prose on both boundary lines, and boundary font sizes
within a 1.1 ratio. Completed sentence punctuation stays decisive even inside closing quotes/brackets. A closing
citation or gene name alone does not end a sentence. A hyphenated continuation requires the completed or
hyphenated word elsewhere in the PDF; uncertain unique words stay split. Blank/figure-only intervening pages,
headings and displays are not bridged. Same-page joining keeps its prior behavior.

The broad replay exposed duplicate layout boxes after a newly joined fragment. The cross-page continuation now
participates in duplicate suppression, including an unfinished duplicate, without changing unrelated same-page
duplicate behavior. Regression tests cover this with an inline equation and both source places.

No GPU training is necessary for this state/assembly defect. The existing v5a model pack, official arXiv HTML
precedence, PDF acquisition policy, page arrangement and full-screen PDF controls remain as before. A joined
paragraph keeps the individual source regions for Show in PDF; it does not create a rectangle spanning pages.

## Results and limits

**Primary result: 60 → 26 breaks, a 56.7% reduction.** Development repairs 15/30; validation repairs 19/30.
The biology PDFs gain 38 correct continuations: 34 in the primary cohort and four in an abstract, supplementary
description, data-availability statement and continued caption. Those four are excluded from the primary metric.

The unchanged model answers were replayed across **99 PDFs / 2,699 pages**: six new biology PDFs plus all 93
existing PDFs. Every replay has **zero missing tagger answers and zero missing recognition crops**.

| Corpus | PDFs / pages | New continuations |
|---|---:|---:|
| Biology | 6 / 167 | 38 |
| Existing arXiv development | 30 / 862 | 182 |
| Existing arXiv test | 32 / 872 | 139 |
| Existing publisher PDFs | 31 / 798 | 125 |
| **Total** | **99 / 2,699** | **484** |

Of the 446 existing-corpus joins, 354 have exact surrounding prose in one accepted source paragraph; the other
92 were reviewed against text extracted from their actual PDF regions, with rendered inspection of ambiguous
examples. The 34 primary biology joins have the JATS paragraph evidence; the other four were inspected as PDF
images. No incorrect final join was found in this audit. This is observed precision on these cases, not a promise
of zero errors on future PDFs. Rejected initial candidates included page counters, an author name, equation
numbers, a small caption/footer joining body text, and false word completions caused by missing/misordered regions.

The strict comparison uses **reader.json** IDs with provenance, not diagnostic `index.json` trace IDs (which can
diverge after expanded references or omitted figures). It accounts for every paragraph, permits only whitespace
normalization and supported boundary hyphen handling, verifies all other block content/order, and compares every
source region and equation rendering gate. All 99 comparisons pass. The **60,864 emitted equation identities,
LaTeX readings, display flags, confidence/rendering decisions and PDF locations are identical** before/after.

On the 83 papers accepted by the existing HTML scorer:

| Metric | Development before → after | Test before → after | Publisher before → after |
|---|---:|---:|---:|
| Text F1 | .900 → .900 | .899 → .899 | .856 → .856 |
| Whole-block match | .825 → .837 | .829 → .838 | .816 → .825 |
| Adjacent blocks in order | .943 → .944 | .939 → .939 | .912 → .912 |
| Inline glyph match, automatic realignment | .933 → .933 | .927 → .922 | .845 → .845 |

The last test metric decreases despite unchanged equation content: the scorer recomputes word anchors after
paragraph/word joins. On 2610.28366, aligned inline formulas change 936 → 824 and matched glyph sets 808 → 646;
2610.26053 adds one aligned formula. This is a real change in the **reported diagnostic**, not hidden or rounded
away. The independent per-equation identity/content/source/gate fingerprints and paragraph conservation prove
that the math output itself did not change. Do not use newly paired formula scores as a fixed-pair regression
test after changing text segmentation. Ten papers lack accepted HTML references and remain covered by the
recorded-output and boundary audits only.

Remaining failures are substantial. The fix intentionally abstains on ambiguous typography, short fragments,
unique hyphenated words, capitalized continuations and intervening pages. It does not remove journal furniture,
repair missing regions, rebuild reading order, relink captions, fix table headers or correct garbled characters.
In particular, all eight measured breaks in eLife 88793 remain because page furniture interrupts the text.
The next bounded quality target should be repeated margin text and its effect on navigation/continuity, followed
by a separately annotated figure-caption relation task. The six biological papers cover only two publishers;
scans and handwritten material are not measured by this result.

## Verification and reproduction

- Twelve focused converter tests cover joins, source places, closing punctuation, hyphens, font transitions,
  counters, short labels, blank/figure-only pages, intervening structure, figures above continuations, duplicate
  boxes and inline-equation ownership. `npm test` passes the normal fast gate.
- The Core Swift regression `ShowInPDFTests.testJoinedParagraphSearchesBothRecordedPagesForTheSelectedPassage`
  passes: selecting text from either half of a joined paragraph searches both recorded pages and returns the
  page containing those words. This checks location resolution, not a new full-screen UI journey.
- The generated port-18 compiler passes Apple JavaScriptCore replay with JIT disabled: 29 pages, zero tag misses,
  5.94 seconds for the converter in the final run. This is a Mac measurement, not iPhone performance.
- A fresh **29-page eLife 106496 full Core ML conversion** with the actual 25 app rules and JIT disabled passes,
  retaining all seven expected joins and source places; no recognition failures, warnings or degraded images.
  Its PDF/XML and native model inputs are saved. No physical phone or Simulator was used in this change.

Durable local evidence is under
`/Users/benbowlwes/science-reader/.artifacts/pdf-reading-quality-20261026/`: `comparison.json`, source-hashed corpus,
baseline/candidate bundles, native records, `*-continuity-diff.json`, `*-audit.json`, `equation-invariance.json`,
`pdf-review/`, the weakness report, compiler identity, exact native command and check logs. Replays use blank image
pixels of the requested size; visual judgments use original PDF rendering and the fresh native bundle.

Local reproduction (slow, explicit; no network needed once the corpus exists):

```sh
python3 scripts/device-pdf-models/publisher_reference.py CORPUS
python3 scripts/device-pdf-models/publisher_quality.py CORPUS BEFORE BASELINE_QUALITY.json
node scripts/device-route-replay.mjs --from BASELINE_VARIANT --to CANDIDATE_VARIANT
python3 scripts/device-pdf-models/compare_continuity.py BEFORE AFTER DIFF.json tests/fixtures/device-pdf/continuity-corpus.json
node scripts/device-route-continuity-references.mjs EXISTING_CORPUS BEFORE REFERENCES.json
python3 scripts/device-pdf-models/audit_continuity.py DIFF.json REFERENCES.json AUDIT.json
```

The baseline/candidate directory names for the replay live under `.artifacts/device-route/accuracy/`. The frozen
fixture argument fixes the acceptance denominator and checks the PDF hashes, original block IDs and source places;
the comparator fails on missing baseline/candidate papers or conservation failures. Wrong-hash and wrong-place
negative controls were rejected. An exploratory `BASELINE_QUALITY.json` can be supplied instead, but it must not
replace the checked-in fixture for acceptance. Omit the final argument for conservation-only comparisons of the
existing corpus. `publisher_quality.py` is an alignment aid. Native CLI `--rules` requires the comma-separated
rule list and `--authors` requires semicolon-separated names; bare `--rules --trace` is not an app-configured run.
Misconfigured exploratory runs were excluded before baseline scoring.

All acquisition, inference, rendering and evaluation ran on the user's Mac. No NAS access, server PDF processing,
migration, hosted change, paid model use or new monthly commitment. Incremental service forecast: **$0/month**.
