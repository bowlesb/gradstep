# Fast and slow tests

Owner direction, 2026-10-13: run fast checks routinely; run slow checks once for a baseline, then selectively for
related changes or a reported problem. A slow run is not a prerequisite for an unrelated edit. Save failures and
turn a discovered bug into a small fast regression where possible.

## Commands

Install root and browser dependencies with `npm ci` and `npm ci --prefix apps/web` (Node 24+).

| Tier | Command | Scope |
|---|---|---|
| Fast, default | `npm test` or `npm run test:fast` | Backend contracts, browser units, authored bundle/crypto fixtures, compiled device-reader freshness. No browsers, downloads, databases, Simulator, credentials or paid calls. |
| Fast, targeted | `node --test tests/backend/arxiv-html.test.ts` or `npm run test:fast --prefix apps/web -- tests/bundle.test.ts` | Exactly the selected files. `test:backend` alone runs all backend contracts. |
| Slow, reader journeys | `npm run test:slow` | Production-CSP browser compiler, complete HTML reader/chat admission, local PDF worker and membership/reselection cases. Local fixture backend only. |
| Slow, real corpus | `npm run test:slow:corpus` | Offline replay of eight exact arXiv revisions through Chromium, Firefox and WebKit; independent bundle verification, math/images/fragments, device-only PDF intake/reload. |
| Slow, native | `npm run test:slow:native` | iPad Simulator WKWebView compiler, PDF admission, locked/over-limit PDF rejection, real-PDF PDFKit rendering and encrypted store reopen. Never selects a physical device. |
| Saved evidence | `npm run test:status` | Shows last result, duration and whether tested source has changed. Does not rerun anything or turn stale evidence into a pass. |

`test:slow` accepts Playwright selectors, e.g. `npm run test:slow -- --project=desktop --grep reselection`.
The corpus command accepts the same flags. Selection flags are recorded in the run report; a selected run is not
evidence for the whole suite. Native flags may override the default iPad Simulator destination.

The existing full browser `npm run e2e --prefix apps/web`, standalone podcast E2E, Swift Core, complete Xcode,
database (`test:database`), operations and hosted checks are also **slow / explicit**. They keep their existing
commands and prerequisites. There is deliberately no default command that launches all infrastructure checks.
Hosted or metered checks retain their existing authorization and budget rules; these new suites never call providers.

## Corpus setup and boundaries

On the user's local development computer, run **once**:

```sh
npm run test:slow:fetch
npm run test:slow:corpus
npm run test:slow:native
```

Fetch is explicit and refuses CI/Cloud Run environments. It uses only official exact-revision URLs, no redirects,
bounded downloads, a single request at a time, and at least three seconds between requests. HTML, images and PDFs
stay in gitignored `.artifacts/reader-corpus/`; they are never uploaded, committed, copied to SSH or served by the
fixture backend. No source scripts execute. Tests use the cached bytes, make no live arXiv calls, and validate
SHA-256/lengths against `tests/corpus/reader-lock.json`. Missing cache is an actionable failure in browser tests;
the optional native corpus case explicitly skips when absent. A future device PDF model is not tested or claimed.

`tests/corpus/reader.json` records identities, coverage, expected counts and reviewed unavailable outcomes. Six
sources are expected to render; KAN v1 exceeds the existing cumulative image-pixel limit, and DeepSeek-V2 v1 has
an official `ltx_ERROR` conversion node. Those cases must return their exact finite failure category with no partial
bundle. They are **unavailable-source checks**, not successful reader conversions. Their original PDFs remain part
of the local PDF corpus. Source changes fail checksum checks; refresh only after review with
`node scripts/fetch-reader-corpus.mjs --on-this-device --update-lock`, then review the lock diff and outcomes.

The PDF corpus covers 278 pages across eight documents, including a 36.2 MB image-heavy original. Authored worker
cases cover text, image-only scans, rotated pages, object streams, 250/251-page boundaries, zero pages and damaged
input. Native checks additionally cover a genuinely password-encrypted PDF. Browser membership tests check
encrypted metadata sync, no PDF/Storage/OCR requests, reload requiring file reselection, wrong-page-count rejection
and no duplicate membership after reattachment. Safari/WebKit account tests retain the explicit durable-X25519-key
capability gate; standalone compiler/worker tests do not depend on that gate.

## When to rerun slow checks

- HTML adapter, SVG rasterizer, MathML, bundle validators, CSP or reader bridge: affected authored journeys plus
  the relevant real sources/engines. Run the whole corpus when a shared contract changes.
- PDF intake, worker, encrypted store, account lifecycle or membership: PDF journeys and relevant native cases.
- Database/migrations, deployment configuration or hosted behavior: the corresponding database/operations/hosted
  checks, with no server PDF corpus or Mathpix fallback.
- New source failure: reproduce locally, retain its exact revision/checksums, add an authored regression, rerun
  affected checks and record the outcome. No automatic download loop.

Reports and logs are in `.artifacts/test-tiers/`, browser failure traces in `.artifacts/web-e2e/results/`, corpus
results in `.artifacts/reader-corpus-results/`, and native evidence under `.artifacts/reader-integration-build/`.
Source fingerprints are conservative signals, not a requirement to repeat slow checks after every change.
Current measured evidence and limitations are recorded in [implementation status](IMPLEMENTATION_STATUS.md).
