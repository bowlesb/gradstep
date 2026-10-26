# Repeated PDF headers and footers — 2026-10-26

Status: port 19 verified locally; not released or deployed. The owner asked to pick and fix another concrete issue
after the scientific-PDF reading audit. The selected problem is long running margin text entering the reading,
Contents and paragraph flow. This changes the local converter, not model weights or reader interactions.

## Target and baseline

Before implementation, freeze the 76 emitted intrusions in eLife 88793: 16 article-type headers, 16 subject
headers, 22 citation footers and 22 page counters. Seven subject headers become false Contents entries.
Require at least **80% fewer intrusions and zero remaining false Contents entries**, without deleting article
content or changing reference order. Baseline: `b544eb71`, port 18.

The existing filter recognizes margin lines with at most eight words after digit removal. PDF extraction puts
the left and right headers on one baseline; together they have nine words. The citation and page counter form
a ten-word line. Both exceed the limit. A header can also share a detected region with genuine body text, so
deleting whole regions would lose content.

The fixed labels, source digests, original block IDs, text offsets and PDF places are in
[`margin-corpus.json`](../../tests/fixtures/device-pdf/margin-corpus.json). The primary cohort was frozen before
the fix. The three additional changed papers were annotated during regression review; they are not an untouched
held-out evaluation. Physical PDF lines, emitted spans and Contents entries are separate units.

## Implementation

The existing short-line filter stays as before. `longMarginGlyphs` extends it conservatively for longer lines:

- The whole line lies in the outer 6% at the top or bottom, separated from the next inward overlapping line by
  at least 0.75 times its font size. It is no larger than 1.05 times the median body font size.
- The text recurs on at least three distinct pages with consistent page height, font families, font size and
  bounding coordinates (within two PDF points). Only an explicit trailing `n of m` or `n / m` counter varies;
  other numbers and dates remain literal.
- Rotated text, OCR glyphs, and text covered by figure, table, caption, display or listing detections abstain.
- The result is a set of actual glyphs on each page, not a global blacklist of those words. An identical sentence
  in the article body remains. Mixed header/body regions retain their body text and a narrowed PDF source box.

Filtering happens **after layout order and glyph ownership are established**, before tagging and reading text.
The initial placement of the filter before orphan-region construction moved three bibliography entries in an
overlapping layout. The conservation gate rejected that draft. Moving the filter later preserves the original
reference order; the rejected native run is retained separately as `native-initial/`, not acceptance evidence.

The existing paragraph-continuation guards reconnect text after a removed header. There is no new paragraph
joining rule, acquisition path, model training, cached-reading migration or UI interaction.

## Measured result

| Paper | Verified intrusions before → after | False Contents entries before → after | Restored continuations |
|---|---:|---:|---:|
| eLife 88793 | **76 → 0** | **7 → 0** | 5 |
| arXiv 2610.27142v1 | 7 → 0 | 0 → 0 | 3 |
| arXiv 2610.26832v1 | 22 → 0 | 0 → 0 | 1 |
| arXiv 2610.28350v1 | 4 → 0 | 0 → 0 | 0 |
| **Total** | **109 → 0** | **7 → 0** | **9** |

The primary target improves 100%, exceeding the 80% threshold. The four PDFs contain 62 newly suppressed physical
margin lines; some lines previously emitted more than one block. All four header/footer styles were inspected in
rendered source PDFs. The nine new continuations were reviewed as complete sentence boundaries.

All **99 PDFs / 2,699 pages** were replayed. The other **95 readings are identical**, including their source
provenance apart from the converter build identity. For the four changed readings, the gate removes only the
PDF-reviewed baseline spans, then requires every surviving paragraph verbatim or as an ordered concatenation;
all nonparagraph text, including references, remains in order. All **60,864 equation records** retain their
identities, content and source/rendering decisions. Figure content and PDF regions remain; figure/block IDs can
renumber when preceding unwanted blocks disappear. Each new source region belongs to the original text that
it represents, including narrowed mixed regions and joined paragraphs.

Every replay has zero missing tagger answers and zero missing recognition crops. Actual Core ML supplied the
new context-dependent tagger answer. Sampled reused answers were checked with the installed model pack (27,826
glyph decisions, zero disagreements and zero logit difference). No recognizer crops needed new answers.

One parallel model-verification process failed closed on an unusable tagger output. The sequential retry passed;
the failed run was excluded and its log retained. This change does not claim to resolve intermittent Core ML
execution failures. The final actual native conversion also completed successfully.

## Validation and reproduction

- Seven focused Node tests cover repetition, page counters, position/font constraints, close body lines,
  protected regions, OCR/rotation, changing numbers, duplicate body text and mixed-region PDF locations.
- `npm test` passes the normal fast gate, including existing paragraph-continuity and PDF-position tests.
- A fresh **22-page eLife 88793 native Core ML conversion**, with the actual 25 app rules and JavaScriptCore JIT
  disabled, passes the same content/source gate. No recognition failures, warnings or degraded images.
- JavaScriptCore replay of that complete native record also passes with JIT disabled and zero missing tags.
- Negative controls reject a missing body word, a duplicated paragraph, reordered references, a wrong PDF digest
  and a changed baseline source label. Checking text F1 alone would not protect these properties.

The evaluation is offline and explicitly slow. With source records and output directories prepared:

```sh
node scripts/device-pdf-models/audit_margins.mjs RECORDS DETECTIONS.json
node scripts/device-route-replay.mjs --from COMPLETE_RECORD_VARIANT --to CANDIDATE_VARIANT --corpus CORPUS
python3 scripts/device-pdf-models/check_margins.py BEFORE AFTER tests/fixtures/device-pdf/margin-corpus.json SPLIT CHECK.json
```

Use `bio`, `dev`, `test` or `venue` for `SPLIT`. `complete_span_replay.mjs` supplies any missing model answers using
the actual local host; partial replay output is never accepted. `audit_margins.mjs` proposes physical lines for
review; it is not independent ground truth. The checked-in labels are the authorization for text removal in the
conservation gate. Existing unrelated papers must remain identical.

Durable evidence: `/Users/benbowlwes/science-reader/.artifacts/pdf-margin-text-20261026/`, including source-pinned
labels, `comparison.json`, `check-*.json`, `detections-*.json`, `model-*/audit.json`, `negative-controls.json`,
`pdf-review/`, complete model records, native commands/output, compiler identity and fast-check logs.

## Limits and next gap

This is a targeted improvement on four observed layouts, not a general header-removal accuracy claim. Unusual
positions, changing text, two-page documents, OCR/scans and text inside figures can remain. The old short-line
heuristic is not revalidated as universally safe by this result. Other layout-order, caption attachment, table
structure and character-extraction failures remain. Figure-caption attachment is the next separate task; it
needs PDF-reviewed relation labels rather than a word-overlap score.

All processing stayed on the user's Mac. No NAS access, server PDF processing, deployment, physical-phone work,
paid inference or new service commitment. Incremental service forecast: **$0/month**.
