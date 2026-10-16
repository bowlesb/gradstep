# Saved model comparison evidence

This is the 2026-10-16 first screening: 12 shared questions, 13 usable settings, and a separately blocked
DeepSeek route. Read [the measured results](../MODEL_COMPARISON_RESULTS_20261016.md) before interpreting scores
or costs. The full 27-question finalist evaluation remains pending.

`evidence.json` preserves 168 contestant attempt records, 15 grading calls, separate primary and secondary
grades, source hashes, selected provider price snapshots, manual source checks and unresolved cost reservations.
It contains model responses, not private account credentials or the full paper/image request bodies.

Verify integrity from this directory with `shasum -a 256 -c evidence.sha256`. From the repository root,
`node scripts/model-bakeoff-viewer.mjs` builds the answer comparison without making paid requests. It reads
local run artifacts when present and otherwise uses this archive. Source questions are in `tests/model-bakeoff/`.

Completion-reported costs and the provider's aggregate usage disagree. Preserve both readings and the five
unknown-charge holds; this archive is evidence for reconciliation, not a reconciled invoice. Never overwrite
these records to make a rerun appear to be the original experiment.
