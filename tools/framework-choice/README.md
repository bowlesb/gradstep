# React / Svelte comparison

An isolated, local-only experiment for the [framework evaluation](../../docs/architecture/WEB_FRAMEWORK_EVALUATION.md).
It does not connect to Supabase, use credentials, call paid providers or change either product application.

## Reproduce

Use Node 24 or later. From this directory:

```sh
npm ci
npx playwright install chromium webkit
npm run build
npm run bench
node summarize.mjs
```

Playwright's browser installation downloads its managed binaries. The runner starts an ephemeral HTTP server
bound to `127.0.0.1` and closes it after the run. A complete run took about seven minutes on the recorded M1 Max.
Do not run multiple comparisons concurrently or interpret measurements taken during other heavy work as equivalent.

For a quick functional smoke check:

```sh
REPEATS=1 RATES=1 npm run bench
```

This overwrites the local `results.json`; rerun the full default comparison before publishing canonical evidence.
`summarize.mjs` rejects incomplete runs and writes the summary and raw data to
`docs/research/framework-choice-2026-10-07/`. Review changes before committing new measurements.

## Design

- `build.mjs` emits independent production builds: manually memoized React, the same React source with Compiler
  1.0.0 enabled, and Svelte 5. Build output reports raw/gzip/Brotli JavaScript sizes, excluding CSS/HTML.
- `shared.js` supplies identical fixture generation, immutable progress updates, filter/sort and window calculations.
  Both frontends use the same row content and `shared.css`; framework-generated DOM nodes may differ.
- Cases: 1,000 rows all rendered; 4,000 all rendered; 4,000 windowed; 50,000 windowed. Windowing renders at most
  26 rows with a 520px viewport and 52px rows. This is a comparison scaffold, not a production virtualizer.
- Seven repeats × three variants × four cases × two CPU rates (normal and 4× throttled) = 168 samples, in fresh
  browser contexts with rotating variant order. The compiler and ordinary React variants retain the same manual
  memoization, as recommended for existing code.
- Fixtures are prepared before timed population. Each operation records Chromium task/script/layout duration,
  wall time and long tasks. Timed controls use DOM input/click dispatch to avoid Playwright locator overhead scaling
  with the list. Separate WebKit checks use typing and keyboard activation.
- Updates change 10% of progress values; filtering selects the diffusion topic; sorting uses descending title;
  scrolling visits five positions; an independent chat component appends 60 plain-text chunks at 16ms intervals.
- Assertions check the resulting rows, counts, progress, last-paper reachability and exact streamed content.
  WebKit checks focus, Enter activation, scrolling and library-title selection during an adjacent stream update.

Raw memory is post-GC **JavaScript heap**, including prepared fixtures, not total process memory. Population time
is not cold application startup. Stream timings do not represent equation rendering, long transcripts or provider
latency. The report records further limitations and the distinction between these fixtures and current product
capacity.

`dist`, local measurements, screenshots and logs are ignored. The published evidence is the complete run captured
in `docs/research/framework-choice-2026-10-07/`. It contains only synthetic data and local measurements.
