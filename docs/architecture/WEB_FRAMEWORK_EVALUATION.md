# Web framework evaluation

Date: 2026-10-07. Status: investigation complete; **owner selected React for both web apps** ("react it is then").
Audited integration commit: `4261808`. No product framework, infrastructure or database changes were made for this study.

## Recommendation

Keep **React + TypeScript + Vite for both the browser reader and the admin**. Share a small set of presentation
components and conventions as they are needed. Keep encryption, library reconciliation, API contracts and reader
verification in ordinary TypeScript, with thin framework adapters.

Both React and Svelte can support the intended application. Svelte's smaller initial JavaScript payload is a real
advantage. The controlled tests did not establish a large-library interaction advantage sufficient to justify
rewriting both existing interfaces. Standardizing on either framework would provide consistency; React already
provides it here. This recommendation is based on the combined maintenance and verification work, rather than a
claim that Svelte lacks features or that a modest rewrite is unaffordable.

SwiftUI/Catalyst remains the shared Apple application. The static information site needs no UI framework. Web
standardization does not require combining the customer and admin deployments, authentication flows or privileges.

## Existing implementation and migration surface

| Surface | Current code | Consequence of changing to Svelte |
|---|---|---|
| Browser reader | 896 lines across UI, hook and entry files; about 1,846 other source lines | Convert views and their lifecycle integration; retain most TypeScript services, CSS, reader frame and tests |
| Admin | 974 production TSX lines, 36 components and 3 hooks; 155 fixture TSX lines separately | Convert views, dialogs, chart interactions and auth integration; revalidate operational workflows |
| Admin services | 116 plain TypeScript lines; 153 CSS lines | Mostly reusable |
| Native Apple reader | SwiftUI/Catalyst, with a shared JavaScript reader bridge | Neither web choice replaces or improves its native UI reuse |

These are physical source-line counts, including comments, whitespace, types and embedded helpers; they indicate
review surface, not an estimate of implementation time. The combined production UI surface is approximately
1,900 lines. It is small enough to change if there is a compelling benefit.

Neither web app depends on a React-only component, editor, table or chart framework. The admin uses custom SVG
charts and native HTML dialogs. Its Supabase client is framework-neutral. The browser's runtime dependencies are
React and React DOM; its device keys, WebCrypto wire format, reconciliation and bundle verification are separate
modules. There is no identified dependency that disqualifies Svelte for the planned product.

Admin migration adds verification work beyond converting markup:

- Password sign-in, MFA enrollment/challenge, role gating and stale-account state clearing.
- Credit grants, account disabling, confirmation behavior and operation-ID reuse after an uncertain reply.
- Support thread selection, reply retries, private attachment cancellation and object-URL cleanup.
- Chart resizing, keyboard navigation, tooltips, tabular alternatives and focus restoration.

Server authorization and billing invariants remain in place under either framework. The concern is preserving
client behavior during conversion. Existing backend/database tests survive a migration, but do not prove these
UI lifecycle behaviors. The audit found no dedicated admin component-test suite.

The two apps currently share no React components. Practical reuse candidates are the brand, design tokens,
accessible dialog behavior, button/field conventions, pending/error states and table controls. Extract proven
duplication incrementally; keep the customer key lifecycle and admin MFA/privileged operations separate.

## Controlled experiment

The [reproducible prototype](../../tools/framework-choice/README.md) compares production builds of React 19.3.0,
React with Compiler 1.0.0, and Svelte 5.57.2, using Vite 8.3.2. It is an isolated experiment, not a rewrite of
Gradstep. All variants use the same fixtures, filtering/sorting functions, styles and fixed-height row window.
React uses memoized rows and derived lists; Svelte uses immutable `$state.raw` data and `$derived` values. This
compares plausible optimized implementations rather than an intentionally inefficient React baseline.

On an Apple M1 Max, Playwright Chromium 153.0.8010.12 ran **168 samples**: seven repeats of each of three variants,
four dataset/rendering cases, at normal speed and 4× CPU throttling. Variant order rotates between repeats. Every
sample verifies filtering, sorting, progress updates, scrolling to the last paper and exact streamed text.
Playwright WebKit 26.6 also passed the three variants' 50,000-row window, typing focus, Enter activation, scrolling
and library-title selection preservation during an adjacent text update.

### Production JavaScript payload of the prototype

| Variant | Uncompressed | gzip | Brotli |
|---|---:|---:|---:|
| React | 223.5 kB | 69.4 kB | 59.6 kB |
| React + Compiler | 225.9 kB | 70.4 kB | 60.5 kB |
| Svelte | 40.5 kB | 15.9 kB | 14.3 kB |

kB means 1,000 bytes. This is the experiment's JavaScript, not the complete application's download. Svelte saves
about 53 kB gzip here. That matters most on an uncached visit or slow connection; the experiment does not measure
those network conditions. The recovered React browser application's separate production build emitted 395.76 kB
JavaScript / 123.22 kB gzip. Its payload includes product functionality absent from the experiment, so the
prototype ratio must not be applied to the whole application.

### Main-thread task time

Medians of seven samples, in milliseconds, measured with Chromium's `Performance.getMetrics`. “Populate” means
putting already-prepared data into a running UI. It excludes data transfer, authentication, sync and fixture
generation. Windowed cases render at most 26 paper rows.

| Case / operation, normal CPU | React | React + Compiler | Svelte |
|---|---:|---:|---:|
| 4,000 rows, all rendered: populate | 237.3 | 236.1 | 191.9 |
| 4,000 rows, windowed: populate | 6.1 | 6.2 | 6.1 |
| 50,000 rows, windowed: populate | 6.3 | 6.1 | 6.0 |
| 50,000 rows, windowed: update progress on 10% | 2.2 | 2.3 | 2.3 |
| 50,000 rows, windowed: filter | 12.2 | 12.5 | 11.3 |
| 50,000 rows, windowed: sort | 30.0 | 29.9 | 28.7 |

At 4× CPU throttling, populating the 50,000-row window took 23.9 / 24.9 / 22.4 ms; filtering took
41.3 / 42.4 / 39.5 ms; sorting took **124.7 / 123.4 / 117.8 ms**, respectively. Sorting is still enough work to
block interaction in all variants. That is evidence for improving the data/query work, not for promising that
virtualization alone solves responsiveness.

For normal-speed 50,000-row population, ranges were 6.18–6.58 ms (React), 5.86–6.33 ms (Compiler) and
5.66–6.30 ms (Svelte). Small median differences on this machine should not be promoted into a universal winner.
The major measured improvement was windowing: approximately 237 to 6 ms in React and 192 to 6 ms in Svelte at
4,000 rows. The compiler made little difference to this already memoized implementation.

Post-GC JavaScript heap with 50,000 prepared records was approximately 11.6 / 11.6 / 11.2 MiB. This is not total
browser memory and is not a memory budget for real papers, images, transcripts or reader bundles.

### What the experiment does not establish

- It does not prove that the current product supports 50,000 papers. Its fixtures bypass the live protocol.
- It does not measure initial network loading, Supabase query plans, reconciliation or offline storage performance.
- The stream is 60 plain-text appends in an isolated component, without long transcripts, equations or citations.
  The selection check concerns a library title beside that component, not text inside a changing answer.
- One filter change and five scroll jumps do not measure sustained typing, trackpad scrolling, INP, assistive
  technology behavior or production variable-height table accessibility.
- CPU throttling is a sensitivity check, not a substitute for testing a real slower device. WebKit checks establish
  limited functional parity; they are not Safari performance measurements.
- Seven repetitions support medians/ranges, not a reliable tail-latency percentile or broad statistical claim.

The saved [summary](../research/framework-choice-2026-10-07/summary.json) and
[all measurements](../research/framework-choice-2026-10-07/measurements.json) include versions, timings, heap,
DOM counts, long tasks and verification outcomes. The browser's existing 28 unit/protocol/Swift–WebCrypto tests
and production build also passed locally during recovery; that is separate from this benchmark and does not
establish live deployment or complete browser workflow correctness.

## Large-library architecture findings

Code review, separate from the performance measurements, found:

- Both the browser and native library protocols enforce a **4,000 retained-entry limit**, including import entries.
- The browser reconciler fetches the bounded baseline and catch-up before publishing the initial library. Each
  baseline page copies the accumulated Map and validates cross-entry identities.
- The current browser table filters/sorts synchronously and renders every matching row.
- Import progress advances a timer in parent state; the complete library object flows through the rows.

These are the current scaling constraints whichever framework is chosen. Before increasing supported capacity,
design a paged query/read model and durable local cache with explicit snapshot/cursor, deletion, account isolation
and resync behavior. Do not remove the safety limit and call the library scalable. Decide which operations use
server indexes and which need offline local indexes; preserve the stated privacy of device-local reading data.

Implementation priorities following the framework decision:

1. Fix account/session cancellation and cache invalidation, including sign-out/relogin without reloading the page.
2. Introduce accessible table windowing with stable row identity, keyboard focus and selection behavior; contain
   progress/chat updates so unrelated parts of the screen stay idle.
3. Design and review incremental loading, persistent metadata, indexes and sync evolution before changing contracts.
   Define bounded caches and eviction separately for metadata, PDF originals and rendered bundles.
4. Exercise realistic search/add/tag/read/chat/offline journeys with large fixtures and delayed/failed responses.
   Include variable row heights, Safari, long equation-rich transcripts and concurrent imports.

These are proposed next steps, not claims of completed implementation. Rendering improvements have measured
benefits here; loading/sync improvements are motivated by source inspection and still require their own tests.

## What Immich demonstrates

The review used Immich commit `26b8e3d40081dc5c70d8a0b3d689b963b8d0779e`. Its
[timeline manager](https://github.com/immich-app/immich/blob/26b8e3d40081dc5c70d8a0b3d689b963b8d0779e/web/src/lib/managers/timeline-manager/timeline-manager.svelte.ts)
loads time-bucket information first, then schedules nearby/visible content. Its
[intersection handling](https://github.com/immich-app/immich/blob/26b8e3d40081dc5c70d8a0b3d689b963b8d0779e/web/src/lib/managers/timeline-manager/internal/intersection-support.svelte.ts)
and [month rendering](https://github.com/immich-app/immich/blob/26b8e3d40081dc5c70d8a0b3d689b963b8d0779e/web/src/lib/components/timeline/Month.svelte)
limit active work while retaining scroll geometry. The implementation also explicitly manages layout and request
cancellation. Loaded metadata can remain retained, and bucket pagination still has a TODO; it is not evidence
of automatically bounded memory or zero maintenance.

Inference: Immich is useful evidence that Svelte can support a sophisticated large library. Its deliberate loading,
layout and rendering design is the more transferable lesson for Gradstep. The same principles can be implemented
in React.

## Framework maintenance and feature fit

[React Compiler](https://react.dev/learn/react-compiler/introduction) can reduce manual memoization work and is
stable. It does not remove the need to bound a list or improve genuinely expensive operations. The prototype
included it so the comparison did not omit that option. Production adoption should be checked against the actual
code's hooks/lifecycle behavior; this report does not silently enable it.

[Svelte's state model](https://svelte.dev/docs/svelte/$state) supports granular reactive updates and raw immutable
data for large arrays. That can be pleasant to maintain, but still requires careful ownership of async work,
cancellation and derived computations. Its smaller prototype payload is the strongest measured reason to prefer
it here. Neither framework makes an application maintenance-free.

Both have a viable library ecosystem for the planned UI. For example,
[TanStack Virtual](https://tanstack.com/virtual/latest/docs/installation) offers React and Svelte adapters.
PDF/math rendering and the verified iframe/reader bridge already sit outside the UI framework; changing the shell
does not repair equation rendering, chat scroll anchoring or offline synchronization automatically.

Choosing Svelte for both remains reasonable if its authoring model or a strict startup payload budget becomes a
decisive product requirement. The present evidence supports retaining one React stack and spending the effort on
the actual data and workflow constraints. An independent reviewer reached the same recommendation after auditing
the admin and reviewing benchmark fairness.
