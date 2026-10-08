# Browser private-journal gate 1 — local review checkpoint

Status: implementation candidate on `codex/web-journal-20261008`, not deployed. This checkpoint is for independent review, not final delivery acceptance. It starts at main `44bf3c2`, retains the compatibility checkpoint `76ad197`, merges the untested journal draft `5f47f5e` / `7fd85c8`, and incorporates root's isolated test-port change `d1cad9e`.

## Implemented candidate

- Version-2 encrypted IndexedDB journal connected to key preparation, History, ChatSession and the UI. A new profile starts at version 2. An existing version-1 profile stays there until the person confirms they finished/copied work and closed other tabs; deferring continues the existing tab-only chat behavior.
- Draft checkpoints, exact encrypted outbox bytes, atomic root/question submission and draft receipts, validated complete pull pages, partial turn checkpoints and abandoned-owner recovery. Reopening or synchronizing never requests a paid answer automatically. Send still requires current online authority and acknowledgement of its question.
- Persisted account/login generation and admitted writer IDs checked in key-record writes and journal transactions. Same-login tabs remain admitted; an old lifetime or retired writer cannot reclaim admission through Journal.open. Forget removes device/activity/journal records and rotates the retained admission tombstone's incarnation.
- Per-account writer and sync locks, per-composer editor locks and per-turn owner locks. No plaintext or exportable-key fallback. Unknown formats and damaged private records preserve bytes and stop private writes.
- Pull-first fresh-ID rebase with exact predecessor revision validation, precommit causal replacement validation, and atomic draft/turn parent mapping. A concurrent descendant forces replanning instead of persisting an incomplete replacement closure.

## Evidence completed at this checkpoint

- Unit suite: 213 tests across 19 files, including 12 new journal cases using real WebCrypto and fake-indexeddb. Cases include canonical newer typing vs delayed Send, exact receipt acknowledgement, discard/tombstone fences, coexisting tabs, new-login/retired-writer fences, key callback retirement, Forget, missing head/draft/event records, unknown authenticated formats, quota rollback, ambiguous completion, rebase vs a concurrent descendant and fail-closed decoder errors.
- Production build: TypeScript and Vite pass; the existing large lazy diagram chunk warning remains.
- `e2e/journal.spec.ts --project=desktop`: 4 pass against isolated loopback ports 54349 / 4337. The persistent-profile case closes/relaunches Chromium three times: type → committed draft → restart → Send → committed event with missing append receipt → restart → exact event reconciliation → explicit answer → newer draft + partial checkpoint → close browser → interrupted recovery. It asserts one fixture model request, three final events, retained newer text and non-extractable keys.
- Other new Chromium cases: separate live-tab editors and cross-tab sign-out/fresh-login restoration; injected quota abort preserving the prior checkpoint followed by missing-head preservation/lockout; explicit version-1 activation and deferral.
- Existing `chat.spec.ts` paper/general/consent/encrypted-reload/cross-browser journey passes with the active journal.

Fixture network failures are deliberately unbilled: the backend commits an event then returns a finite 503 without its append receipt. Closing a reused socket was unsuitable because Chromium may retry it at the HTTP transport layer. The production code does not retry paid requests.

## Remaining before delivery

Complete controller race coverage (editor/turn ownership, final-save retries, rotation and refused-turn cleanup), rerun full unit/build and full Playwright suite after changes, and finish independent review. Updated compatibility journeys exercise explicitly deferred version-1 profiles and a future version-3 writer; their full run is still pending at this checkpoint.

No hosted/backend/provider requests, schema migration, deployment or physical-phone work was performed. Gate 2 (durable library/saved reader copies) and gate 3 (cold offline startup/static shell) remain unimplemented. Safari's non-extractable X25519 persistence remains a separate support gate. Device storage can be cleared/evicted; local-only drafts cannot be recovered from a cloud recovery code.
