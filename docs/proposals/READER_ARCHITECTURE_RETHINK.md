# Reader architecture rethink — proposal (2026-10-15)

Owner, after two failed first interactions on build 39/40 and a 16-of-58 refusal rate in the first fresh-paper sweep:
"when the failures are this common, it means we've added too much complexity, and not taken care to decouple
things that should be decoupled… it might be time for a rethink of what the architecture is, what the components
are, how quality is assured for each."

This proposal names the components, states each one's contract and quality gate, and gives a three-step plan whose
first step is being applied now. It is deliberately short; the point is the shape, not the detail.

## What the failures actually were

| Failure | Where | Why it was possible |
|---|---|---|
| Abstract before the title, "[ [", a bare date (Urbex) | HTML-to-bundle converter, front matter | The header is reconstructed from LaTeXML's markup, whose shape varies by template; every new shape is a new heuristic |
| Gross author presentation (PRISM, PhysCodeGym, LoongSage) | same | same |
| Old header still shown after the fix (PRISM again) | device reader store | A stored bundle did not know which compiler made it; the store never asked |
| "Exceeds the device reader's preparation limits" (Apertus 1.5) | converter limits | A 2 MiB source cap chosen before real reports were measured |
| 16/58 fresh papers refuse: `arxiv_math_coverage`, `arxiv_nested_content`, `arxiv_equation`, `arxiv_block_text`, `arxiv_title` | converter | The converter refuses the whole paper when any structure is not one it recognises, although the output validator already guarantees safety of whatever it emits |
| Imports stuck at "Finding" | server metadata stage | arXiv changed how it answers one URL form; no canary noticed until the owner did |

The common thread: **understanding** and **safety** were fused into one strict converter, the **header** depends on
the least stable part of the input, **versions** do not flow between components, and quality was checked on a pinned
corpus rather than on what the owner opens today.

## Components and contracts

1. **Acquisition (device only).** Fetches the official HTML revision and its declared assets, paced; takes the catalog
   record (title, authors, abstract, categories) from the library. Contract: bytes + metadata, bounded sizes.
   Gate: the existing acquisition tests; limits set from measured real reports (8 MiB source now).
2. **Converter (pure function; `supabase/functions/_shared/reader/arxiv-html.ts`).** Input: HTML + metadata.
   Output: a bundle (HTML in the reader vocabulary, an index, provenance). **Contract change:** it refuses only for
   safety or size (`arxiv_article`, source/bundle limits, duplicate ids, script-like content); any structure it does
   not recognise degrades — rendered as text, or left out — and is written to a **ledger** in the provenance and
   the closing note. Math it cannot place becomes its text, never a refusal. Gate: unit tests on recorded LaTeXML
   fragments (small, committable), plus the fresh-paper sweep's success rate.
3. **Header from metadata (new, small).** Title, authors and abstract come from the catalog record; the HTML's front
   matter contributes only affiliations and notes, and only when they parse cleanly. The HTML's own title/authors/
   abstract blocks are dropped when they duplicate the metadata. Gate: exhaustive unit tests on the recorded shapes
   (every owner report becomes a fixture).
4. **Validator (unchanged).** Output vocabulary, sizes, image admission; the only thing that may say "unsafe".
5. **Reader bridge (unchanged).** Navigation, Back, selection, passages. Gate: the citation harness, the browser and
   Simulator journeys.
6. **Device store.** Keyed by source revision **and compiler identity**; a bundle from an older compiler is prepared
   again when opened (done tonight). Gate: unit test on the identity file; a journey that opens a stale bundle.
7. **Downstream readers** (chat context, Study, podcasts) consume the index, never the HTML. Unchanged.
8. **Server metadata stage.** Gate: a daily import canary (one fresh paper) so an arXiv change is noticed in hours.

## Quality assurance per component

- **Fresh-paper sweep** (`scripts/reader-sweep.mjs`): the newest papers in the categories the owner reads plus the
  staging library, compiled with the shipped compiler, checked against header and structure invariants. Reported
  as a success rate; run before every reader build; target **≥ 98 % open**, every failure triaged into a fixture.
- **Recorded fragments**: each failure becomes a 1–5 KB fixture under `tests/fixtures/reader-arxiv/fragments/`
  (not whole papers), asserted in the compiler tests. Owner reports stop recurring because they become tests.
- **Pinned corpus** (existing slow tier): browsers and bundle verification on eight exact revisions — kept.
- **Canaries**: a daily import of one fresh paper; a weekly sweep; results in `.artifacts/reader-sweep/` and the
  status doc.

## Plan

1. **Now (this night):** refusals → degradations with a ledger; metadata-first header; the sweep as the gate; raise
   the measured limits; the store's compiler identity. Ship as build 41.
2. **Next:** split `arxiv-html.ts` (1,000+ lines) into front matter, body, math, figures and tables modules, each
   with its own fragment tests; delete heuristics the metadata header makes unnecessary.
3. **Then:** the sweep and the import canary run on a schedule with a one-line summary in IMPLEMENTATION_STATUS.md;
   a reader change that drops the success rate does not ship.

## What this does not change

The security posture (device-only content, no server PDFs, a validated output vocabulary), the bundle format, the
index the chat and podcasts read, and the reader bridge. The rethink is about where understanding may fail safely.
