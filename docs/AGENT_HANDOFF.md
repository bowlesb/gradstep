# Agent handoff

**Current checkpoint, 2026-10-13 PDT:** HTML-first implementation is deployed on staging. Read
[Implementation status](IMPLEMENTATION_STATUS.md) and [HTML-first architecture](architecture/HTML_FIRST_READER.md).
Migration 058 and metadata-only Cloud Run `gradstep-pipeline-00033-2jw` block new server PDF/OCR work. Edge chat
accepts explicit, ephemeral local reader context. Browser Pages `a3127547` and admin Pages `91c1eb33` are deployed.
Native **build 30 is VALID and IN_BETA_TESTING on iOS and Mac**, including the figure compatibility fix.
The hosted DPO v3 journey passed with zero PDF/artifact requests, no provider spend and successful cleanup.

**Test policy and new baseline:** `npm test` is fast (~10 s); slow browser/corpus/Simulator/database/hosted checks
are explicit and reused until relevant changes or a problem warrant rerunning. Read [TESTING.md](TESTING.md).
Eight local PDFs / 278 pages pass browser intake and native encrypted reopen/render. Six of eight HTML sources
render on all three engines; KAN v1 hits the pixel limit and DeepSeek-V2 v1 has a source conversion error, both
recorded as unavailable, not ready. Firefox sign-in previously waited indefinitely for optional storage permission;
the nonblocking fix is deployed in `a3127547`, with 4 new fast regressions and all 8 Firefox PDF journeys passing.
Full baseline: fast 848 tests; authored browser 13 pass / 3 skips; corpus 40 pass / 8 skips; native 8 pass.
All skips are the existing WebKit account-key capability gate; compiler and authored PDF worker still run there.

**Figure fix:** screenshot paper `2610.10478v1` reproduced and fixed (multiple captions plus MuPDF SVG glyph
metadata). Sidebar paper `2610.12978v1` also fixed (inline SVG legends and MathML backgrounds). V2
renderer/provenance retains v1 reading support. Both plus the original corpus pass all three browser engines;
both papers also pass hosted reader/selection checks, with figures and legends visually inspected and zero broken
images, PDF/artifact requests or provider spending. TestFlight build 30 is VALID and IN_BETA_TESTING on both platforms.

Do not revive old PDF downloads, upload sessions, OCR, conversion retries or PDF workflow corpora. Historical
records remain; no legacy migration/deletion was requested. The future local PDF model is not implemented.
Browser PDF bytes remain in the selected device file/tab and must be chosen again after reopening; encrypted
membership/history persist. Durable browser offline bundles remain a later gate. Native stores are encrypted
and excluded from backup. Physical iPhone work remains paused.

Provider spending is $20.744201 / $25, reserved/liability zero; the $100 total budget is unchanged and October
overhead evidence is missing. No NAS or TextBrain changes were made. The complete checkout is verified at `192.168.1.32:/home/ben/science-reader-html-20261013` (1,172 source files plus Git history, refreshed after the integration-test and Firefox permission fix). The earlier checkout is preserved; no credentials, dependencies, build artifacts or processing service were transferred.

The last deployment handoff is [HANDOFF_20261007.md](HANDOFF_20261007.md), beginning with its
**Current takeover checkpoint — 2026-10-08 UTC** section. Read that section, the
[implementation status](IMPLEMENTATION_STATUS.md), [owner feedback](OWNER_FEEDBACK.md)
and [project instructions](../AGENTS.md) before continuing.

The October 5 handoff previously stored here is historical and remains in git history.
Its deployment instructions, old budget, next-build number and open purchase diagnosis
must not be used as current state. The longer current handoff also labels its retained
historical sections explicitly.
