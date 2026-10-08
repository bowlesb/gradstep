# Browser durability and offline reading

**Design and local implementation, 2026-10-08.** The compatibility checkpoint is retained, and the
gate-1 encrypted private journal is implemented on `codex/web-journal-20261008` (not deployed).
See the [current local evidence](../verification/2026-10-08-browser-journal-gate1.md) and
[gate-1 implementation details](#gate-1-local-implementation-2026-10-08). Saved papers, a durable library
checkpoint and cold offline startup remain unimplemented.
This extends [the browser reader](BROWSER_READER.md), follows the
[native journal and recovery contract](PRIVACY_AND_SYNC.md), and carries over the
[native offline-copy policy](NATIVE_OFFLINE_BUNDLES.md). It does not change navigation,
cloud encryption, credit admission, or the backend schema.

Independent read-only review completed on 2026-10-08 against the current key, auth, history,
composer and IDB contracts. Its writer-fencing, owned-turn recovery, legacy-tab and failed-logout
findings are incorporated below. The later implementation review reproduced and corrected stale
writer admission, delayed draft receipts, missing roots, rebase planning and restore ownership races;
the local evidence records their regression tests. Design review alone is not runtime acceptance.

## Recommendation and first delivery

Build one account-scoped encrypted IndexedDB journal first. Persist chat drafts, validated
history, the exact pending event ciphertext, and interrupted-answer checkpoints. Keep the
current online Send requirement for that first release: reload recovery becomes reliable
without adding an automatic paid-request queue. Then add saved papers and a complete library
checkpoint, followed by offline startup and the static app shell.

These are separate acceptance gates. Persisting today's React state would not make the app
usable offline: key preparation currently contacts `v1_key_state`, the library exists only in
memory, and there is no service worker. Safari also remains a separate browser-support gate.
No plaintext or exportable-key fallback is part of this plan.

## Existing contracts that constrain the design

| Current implementation | Consequence |
|---|---|
| IndexedDB `gradstep`, version 1, contains `devices` and encrypted `activity`; device records hold non-extractable X25519 and AES-GCM keys | Extend that database so Forget can retire all account data atomically. Preserve existing keys. |
| `keys.prepare()` validates persisted key usability, fetches current server state and unwraps its recipient envelope | Cold offline startup needs an authenticated cached envelope and local access state, not a serialized raw key bundle. |
| `History` is memory-only, bounded at 20,000 events / 64 MiB wire ciphertext; pending at 128 / 8 MiB | Preserve bounds and distinguish local commit, server acknowledgement and complete pull cursor. |
| Drafts and active answers exist only in `ChatSession` memory | Persist composition identity, revisions and submission receipts, not just the text visible in the textarea. |
| Three verified reader bundles and the complete v3 library view are session-memory caches | A downloaded copy needs durable provenance and library eligibility, not just a saved HTML response. |
| Activity corruption currently returns an empty cache | That behavior must never reset private drafts, pending history or an incomplete pull. |

Sources in the repository: `apps/web/src/lib/{idb,keys,wire,history,chat-session,activity,library,bundle}.ts`,
`ui/{App,Reader,useChat,useLibrary}.tsx`, and migrations 002/039. Current browser in-memory
rotation reseals pending events with their existing IDs. The durable implementation must port
the native pull-first, fresh-ID rebase contract, including its parent mapping, instead.

## One encrypted local journal

Scope records to the exact backend origin/project, account UUID and a random local-store
incarnation. An environment label alone is insufficient when a deployment changes. Adopt an
existing version-1 device record only through an explicit mapping to its known deployment.
The local AES key remains non-extractable; use fresh AES-GCM nonces and domain-separated AAD
for record kind, format, scope and immutable identity. It is not an exportable HKDF seed.
Public IDB keys contain only necessary opaque IDs, scope and counters; paper titles, bindings,
draft text, indexes and chat content remain inside sealed records.

The eventual logical stores are below; create only those required by each delivery.

| Records | Durable content |
|---|---|
| Account head | Authenticated codec/minimum-reader version, incarnation, device binding, local access state, revision, domain roots and bounded counters |
| Private history | Immutable sealed wire events, complete pull checkpoint, exact pending bytes, acknowledgements and atomic rebase mappings |
| Drafts | Composer/conversation/head, text revision, checkpoint revision, submission receipt and discard tombstone |
| Active turns | Stable operation/event IDs, request digest and context, bounded partial text, interrupted/final disposition |
| Library, later | Complete typed rows and checkpoint, dataset context, retained identity mappings and ordered eligibility guards |
| Reader copies, later | Sealed directory/header plus individually sealed verified members; manifest bytes/hash, exact identity and byte counts |

Use bounded binary records rather than base64 wrapping or rewriting a whole history on each
keystroke. Authenticated heads commit to child identities/digests so missing or substituted
records are detectable. A broken private-history root stops private writes with a recoverable
storage error; it is not an empty account. A damaged reader copy can be removed/re-downloaded
without resetting the private journal. This detects corruption, not rollback of an entire
browser profile together with its keys.

Each write captures its account, incarnation, device, authenticated login lifetime, admitted
writer generation/instance, intent and predecessor revision. Persist those admission fences;
retaining a device ID across sign-out is not sufficient. Legitimate tabs within the same login
lifetime remain admitted: opening a new tab must not retire another tab's editor or stream.
Retire earlier login lifetimes and individual writers, and drain accepted work before admitting
a replacement session. A stale callback cannot rebase itself into the new writer generation.
Apply the same check to key-record writers (`persistDevice` / `finishApproved`), not only chat.
Prepare encryption outside the transaction. In one short read/write transaction, compare the
exact predecessor head and admitted scope, then commit records, indexes, counters and the
replacement head together. Publish success on transaction completion, not a request's success.
Re-read/rebase on a bounded compare failure; after an ambiguous completion, inspect the stored
receipt before retrying. IndexedDB transactions are task-scoped, so awaiting WebCrypto inside
one is not safe. Request strict durability where supported, without claiming filesystem-level
guarantees across browsers. [IndexedDB transaction lifecycle](https://w3c.github.io/IndexedDB/#transaction-lifecycle),
[durability option](https://w3c.github.io/IndexedDB/#dom-idbtransactionoptions-durability).

Use a per-account Web Lock for cooperating local writers and a separate sync leader; never
hold the write lock over network requests. Transaction comparisons remain authoritative.
BroadcastChannel messages are invalidation hints containing no private text. Do not silently
fall back to unconstrained multi-tab writes when a required coordination capability is absent.
Each live composer has one editor lock: another tab can focus it or open a separate draft;
it cannot steal it because a wall-clock lease appears old. [Web Locks](https://w3c.github.io/web-locks/).

## Drafts, submission, answers and rotation

- Checkpoint typing with a short debounce and a bounded maximum delay. Drain accepted writes
  before app-controlled navigation or sign-out. “Saved on this device” refers only to the
  committed revision; a browser crash can still lose the newest uncommitted keystrokes.
- Each edit has a new text-revision UUID, even when its text happens to equal an earlier edit.
  A local submission transaction creates the root/question events, seals their exact outbox
  bytes, records a receipt, and consumes only the captured draft revision. Later text or a
  different branch survives. Discard writes a tombstone so a delayed save cannot resurrect it.
- Validate a whole downloaded history page before atomically advancing its local pull cursor
  and matching acknowledgements. An append receipt is not a complete-history cursor.
  Lost acknowledgements retry the same event ID and ciphertext. Local root/question submission
  is atomic; the existing server append API still commits individual events.
- Start paid answering only after current online authority/consent and acknowledgement of the
  captured question. Persist the operation ID, request digest, assistant event identities and
  turn ownership before the request. Reconnection may sync sealed events; it never resumes or
  retries a paid answer automatically.
- Coalesce partial-answer checkpoints to at most once per second within the existing 200 KB
  answer bound. A final/interrupted answer and its related local events enter the outbox in the
  same transaction that retires the active turn. Refusal removes partial checkpoints. A crashed
  turn reopens as interrupted only after acquiring its abandoned owner Web Lock; another tab
  cannot interrupt a still-owned stream, and elapsed time is not proof that its owner died.
  Any retry requires the user. Retrying a failed **save** never
  calls the model. Lost text that was never committed cannot be reconstructed from a server
  plaintext transcript, because none exists.
- On key rotation or author-device change, obtain the current authority, pull completely,
  and acknowledge already committed IDs first. Rebase only absent pending events under the
  native fresh-ID algorithm; commit rewritten descendants, draft heads and the replacement map
  together. Never rewrite committed history. The server's keyring lock fences new old-epoch
  appends; a second tab must discover the committed rebase rather than create another branch.

Cloud synchronization of unsent drafts is outside this milestone, matching the native policy.
The local journal remains useful even if the eventual paid request is refused for no credits.

## Offline access, recovery and retirement

For the later offline-startup slice, save the last authenticated **recipient envelope** and
its account/device/epoch binding inside local AEAD, alongside an authenticated local-access
record. Unwrap it with the existing device private key when offline. Do not persist raw bundle
keys, a recovery code, or an unwrapped management token. Refresh that envelope and local-access
record atomically after a successful online key preparation.

| Event | Required behavior |
|---|---|
| Matching previously signed-in session and local device; network unavailable or access token merely expired | Open eligible saved content, history and drafts; show Offline / last sync. No server writes or paid work without online authorization. |
| Explicit sign-out, including another tab | Immediately retire visible data and requests; disable local offline activation, drain app-owned writes, and retain the encrypted partition. A fresh sign-in is required. |
| Forget this browser | Warn about unsynced work; atomically remove all account records/keys and retire its incarnation. Late writes cannot recreate them. This does not itself revoke a server device. |
| Positive server denial of account/device/session authority | Lock local presentation while retaining encrypted work for recovery. Do not reinterpret denial as a network outage. |
| Cleared/evicted site data or lost local key | Recover cloud-acknowledged history through existing recovery/approval. Local-only drafts and downloads are not recoverable from a recovery code. Preserve unreadable records instead of silently initializing over them. |
| Completed account deletion | Retire all local partitions for that account as well as the normal server deletion path. |

Offline activation requires both the matching saved login lifetime and the sealed local-access
record. It must not reconstruct a session from encrypted cache after logout. A missing session
is a denial even if persisting the logout marker failed. However, localStorage and IndexedDB
cannot commit together, and current session publishing swallows localStorage failures. Before
reporting durable local sign-out/forget, read back at least one durable revocation boundary.
If both session removal and sealed-access revocation fail, hide/retire memory immediately and
report that local access could not be cleared; do not promise post-restart revocation. This is
an offline-startup acceptance gate, not new scope for the first private-journal delivery.
A new login can reopen its retained partition only after online account/key validation; other
accounts never enumerate it.

This trusts the browser profile, like current persistent device keys. It is not an OS unlock
gate or protection against same-origin script compromise. An offline device cannot discover
a remote deletion or quarantine until it reconnects; this matches the native offline promise
and introduces no new expiring offline lease.

## Saved papers and library authority

Use the existing epoch-aware **v5 full** library contract for the durable library slice, with
encrypted upload descriptors and matching v5 online command adapters enabled together. Keep
the 4,000-row bound. Do not switch the read family while leaving Add/Retry/tag writes disabled,
or treat a persisted v3 view as current v5 authority. Compact/query-based larger libraries are
separate [capacity work](LIBRARY_CAPACITY.md), not a prerequisite for the private-journal slice.

Persist only a complete validated baseline plus catch-up, including hidden identity mappings
and tombstones. Record dataset epoch, protocol/capability and deployment. A changed context
requires a fresh baseline and reconciliation; the old copy cannot manufacture a command cursor
or authorize new server work. Library mutation queuing while offline remains out of scope.

Preserve the native explicit **Save offline** / **Remove download** policy and badge in existing
reader/library controls. Ordinary reading can use RAM without silently promising a download.
An already verified RAM bundle may be saved without another descriptor only while its full
binding and current eligibility still match; otherwise fetch through the existing bounded
transport. Persist neither delivery grants nor signed Storage URLs.

Bind every copy to account/deployment/dataset, library item and document/approval/version,
artifact/manifest, membership intent and availability revision. Verify before encryption;
then recheck current intent and eligibility in the final installation transaction. One install
at a time, cancellation and late invalidation must never publish a partial “Downloaded” copy.
On open, authenticate stored bytes and rerun the existing bundle verifier; do not deserialize
a trusted `VerifiedBundle` object or cached DOM. Existing member/manifest/size limits remain.

Known removal, quarantine or incompatibility immediately retires an open handle and persists
an ordered guard. An outage cannot clear that guard, nor can older/unknown library state.
Only a newer authoritative positive state can unblock it. Removing a local copy does not
erase its guard. A guard-persistence failure latches a cache safety error, rather than allowing
an ensuing network failure to reopen the copy as ordinary offline reading. Ordinary service
outages preserve previously eligible copies. These are the existing native semantics.

Keep ciphertext account-local even for shared public papers. Backend artifact reuse does not
authorize cross-account local cache discovery or a client-side deduplication shortcut.

## Capacity and storage failures

Recommended initial bounds preserve current history limits and native copy policy:

| Domain | Bound and overflow behavior |
|---|---|
| History / pending | Existing 20,000 / 64 MiB wire and 128 / 8 MiB pending. Proposed 96 MiB sealed local allocation must be demonstrated against the actual binary encoding. No automatic eviction of unsent work. |
| Drafts / active turns | Existing 128 drafts, 200 KB each / 2 MiB combined, three streams; bound auxiliary receipts/tombstones separately (proposal: 1,024 records / 8 MiB). Reclaim only provably retired coordination records. |
| Library checkpoint | 4,000 rows / 256 MiB sealed, with typed per-row/checkpoint bounds. Do not publish a partial baseline as complete. |
| Reader copies | 100 copies / 512 MiB ciphertext, including directory/header reserve and blocked copies. Explicit removal; no silent LRU eviction. |
| Reader RAM | Selected verified bundle plus bounded verification work. Persistent capacity does not justify hydrating every saved bundle. Measure peak memory. |
| Static shell, later | Proposal: 8 MiB per release, at most two retained releases. Current build is about 6.45 MB including lazy diagram code; enforce build-time bounds. |

Account committed sizes transactionally, including overhead and installation headroom. Storage
estimates are advisory, not a reservation. Quota errors roll back the attempted commit and show
storage controls; they do not erase unsent work or remove library membership. File removal is
not a guarantee of secure erase or immediate browser-disk shrinkage. Request persistence and
report its actual result. Browsers may evict origin data or users may clear it, and quotas vary;
do not promise permanent device storage. [WebKit storage policy](https://webkit.org/blog/14403/updates-to-storage-policy/),
[Storage persistence](https://storage.spec.whatwg.org/#persistence).

## Offline shell and older tabs

The later service worker serves only a bounded, build-generated allowlist of app assets and
the navigation fallback. Include every required lazy chunk, renderer asset and font. Never
cache Auth/API responses, signed URLs, PDF responses or chat text through Cache Storage;
private content stays in the encrypted journal. No Background Sync or provider requests.
The worker does not handle private keys, although same-origin workers are not an independent
security boundary. Allow `worker-src 'self'` only for this reader shell after CSP review; keep
the opaque reader frames and separate admin policy restricted.

Cache Storage and IndexedDB do not share a transaction. Claim offline readiness only after
both shell and account-data gates succeed. A failed shell install must not damage saved work.
Keep compatible assets for existing clients; defer a third release's activation if removing
one of the two retained versions would strand a live client. Do not unconditionally activate
a new worker over an active chat. [Service-worker lifecycle](https://developer.mozilla.org/en-US/docs/Web/API/Service_Worker_API/Using_Service_Workers).

Version both IDB structure and authenticated record codecs/minimum writers. Unknown future
formats fail with an update instruction and preserve bytes. Structural upgrades preserve key
records; perform asynchronous authenticated-data conversions after opening, in bounded atomic
steps. Upgrade blocking asks the user to close an older tab; it never deletes the database.

Ship the update/retirement handshake **before** activating a new schema. Today's version-1 code
closes its connection on `versionchange` and then cannot reopen version 1, but an already loaded
tab may still hold unsaved text and active requests. That is not a safe migration handshake.
The compatibility release helps cooperating tabs; it cannot retroactively drain older code.
For an existing version-1 profile, schema activation is therefore user-controlled: first finish
or copy unsent work in every Gradstep tab, close those tabs, then reopen one current tab and
explicitly acknowledge that step before upgrading. If that step cannot be completed, keep the
profile at version 1 and defer activation. This is user evidence, not a browser-proven census;
a broadcast response set or elapsed timeout cannot substitute for it. Never force a refresh
or erase old storage to make the upgrade proceed.

## Next implementation checkpoint: compatibility only

This checkpoint is independently shippable. It was implemented locally on 2026-10-08; see the
verification section below. Keep IndexedDB version 1, its existing stores, encryption, online behavior and CSP unchanged.
Add a shared storage-lifecycle signal and cooperative update/retirement handling to `idb.ts`,
key operations, `ChatSession`, `useChat` and `App`:

- On retirement, refuse new writes, Send and consent continuations; stop active streams through
  their existing partial-save path while the current account is valid. Finish already accepted
  IDB transactions, close the connection, and reject later callbacks from that retired instance.
- Keep volatile drafts, partial answers and failed saves visible for copying in the current
  page. Do not unmount the account merely because storage needs an update. Preserve existing
  before-unload warnings. State plainly that this release does not save drafts across reloads.
- Give blocked/upgraded-storage errors actionable update/close-tab guidance, separate from
  unsupported cryptographic-key persistence. Cooperating tabs can defer a proposed upgrade
  while work remains. No automatic reload, service worker, database upgrade or durable-save badge.

Estimated verification scope is eight focused lifecycle/controller cases and three real
two-tab fixture journeys, with no paid/hosted requests: accepted write completion versus a late
callback; denied new Send/consent; stopped partial answer; retained newer draft and failed save;
account retirement; blocked upgrade; and a legacy version-1 connection. The browser journeys
must show no duplicate paid request, readable/copyable volatile text, bounded closure of accepted
transactions, and a visible legacy close/reopen barrier rather than an automatic upgrade.
Check the update guidance in light/dark and keyboard navigation. Tests establish orderly
retirement and honest warnings, not durability or offline access.

### Compatibility checkpoint — local verification, 2026-10-08

Implemented in `apps/web` (`lib/idb.ts`, `lib/keys.ts`, `lib/chat-session.ts`, `ui/useChat.ts`,
`ui/App.tsx`, `ui/Keys.tsx`, `ui/ChatPane.tsx`, `ui/StorageNotice.tsx`); not deployed.

- **Lifecycle signal.** `storage.snapshot()` reports `open`, `retiring` or `retired` with an issue:
  `update` (a newer tab changed the database), `upgraded` (opening version 1 failed with
  `VersionError`), `closed` (the browser closed or deleted the database) or `blocked` (this page's
  own open request waits for an older connection; it keeps waiting instead of failing). On
  `versionchange` the page calls `close()` at once, so transactions it already created complete and
  no new one can start; it reports `retired` once those finish and never reopens version 1. Every
  later request, including a callback that began earlier, fails with a `StorageError` naming the
  issue. Read-write transactions request `durability: 'strict'`.
- **Cooperative deferral.** A newer release can post `{kind: 'upgrade-proposal', proposal, version}`
  on the `gradstep.storage` BroadcastChannel. A page holding unsent work replies `ready: false` and
  shows “Another Gradstep tab is ready to update … Send or copy it, then close this tab.” It replies
  `ready: true` once its drafts, streams and unsynced events are gone. Messages carry only a random
  ID and flags. Deferring does not retire the page. A reply set is a hint only: older releases never
  answer, so schema activation still needs the person's explicit confirmation.
- **Key operations.** `exclusive()` and `forgetDevice()` refuse to start once storage has retired,
  so no enrollment request or key write begins from a retired page.
- **Chat.** On retirement `ChatSession` stops active streams through the existing partial-save path
  (an interrupted answer, while the login is still valid), moves a pending consent choice to “No
  answer was requested …”, and refuses new Send, Get answer, Retry saving, consent continuation and
  deletion. Composers become read-only but stay visible and selectable for copying; failed saves stay
  visible and background sync may still acknowledge events accepted before retirement. A question
  saved during retirement is never followed by a paid request. The account stays mounted; the
  existing before-unload warning is unchanged. Account retirement still overrides everything.
- **Guidance.** A row under the top bar says “Gradstep was updated in another tab … copy what you
  want to keep, then close this tab and continue in the updated one. This version of Gradstep doesn't
  keep unsent drafts after a reload.”, with a person-initiated **Reload this tab**. Opening this
  release over a newer database shows the same title with **Reload this page** instead of the
  unsupported-browser message. The composer hint now says drafts stay in the tab only and aren't kept
  after a reload. No automatic reload, service worker, database upgrade or durable-save badge.

Verification: eight lifecycle/controller cases in `tests/storage-lifecycle.test.ts` (accepted write
versus late callback; denied Send/consent/retry/edit; stopped partial answer with one request;
retained newer draft; failed save kept and later acknowledged without AI; account retirement;
proposal deferral and a blocked open; legacy version-1 page that never reopens and reports a newer
database as an update) run `idb.ts` against `fake-indexeddb` 6.2.5 (dev only) and the controller
against fakes. Three real two-tab Chromium journeys in `e2e/storage-update.spec.ts` use the
production build and the local fixture: an update during a streamed answer (one stream request,
three saved events, newer draft read-only and copied through the clipboard with the keyboard, the
newer tab admitted in well under 3 s without `blocked`, before-unload still warns); a reading save
resumed after the update writes nothing and a reload shows the update barrier with the version-2
database and device record intact; and a tab with unsent work defers a proposal, keeps sending, then
releases it when the draft is cleared, with the database still at version 1. Light/dark screenshots:
`.artifacts/web-storage/`. These establish orderly retirement and honest warnings only, not
durability or offline access. Safari remains a separate gate.

### Initial compatibility-only handoff, 2026-10-08

This historical handoff predates the gate-1 work below. Its description of the untested WIP and
tab-only drafts does not describe the current local gate-1 implementation.

Work stopped here at the owner's request (web work moves to Codex). Branch
`worktree-agent-a7d3a326272f0e9f4`, commit `76ad197` (on `42b8730`, no later `main` merged).
Not deployed.

- **Done:** the compatibility checkpoint above, nothing more. IndexedDB stays at version 1.
- **Passing:** `cd apps/web && npm test` — 17 files, 199 tests (191 existing + 8 new).
  `npm run build` — passes (existing >500 kB chunk warning only).
  `npx playwright test e2e/storage-update.spec.ts --project=desktop` — 3 passed.
  Full `npx playwright test` (desktop, phone, webkit) — 74 passed, 51 skipped, 1 failed:
  `library-columns.spec.ts` "chosen columns persist…" at 390 px measured the pane mid-resize and
  passed on immediate rerun (2/2). It is unrelated to storage. The skips are the existing WebKit key-persistence gate
  and phone-skipped desktop-only cases; the new journeys skip WebKit for the same reason.
- **Gate 1 is not done.** Unfinished, unreviewed work is on branch `wip/browser-journal-gate1`
  (`5f47f5e`, `7fd85c8`, on top of `76ad197`). It has:
  - an encrypted journal module (`lib/journal.ts`): hash-chained event records, digest-manifested
    draft and turn records, compare-and-swap commits under a per-account Web Lock, lifetime and
    device fences;
  - a version-2 `journal` store with person-confirmed activation for version-1 profiles (`idb.ts`);
  - History restore, pull, outbox and fresh-ID rebase persistence;
  - ChatSession draft checkpoints, submission receipts, turns and turn recovery.

  It is **not wired** into `useChat`/`App`, so no journal ever opens. It has no activation dialog
  and no journal tests. It typechecks and keeps the 199 unit tests passing. Treat it as a draft to
  review or discard, not as gate-1 evidence. No drafts survive a reload on any branch.
- **Next (as designed above):**
  1. Review and wire the WIP.
  2. Add journal unit tests (`fake-indexeddb`, injected locks) for the race list.
  3. Add persistent-profile Chromium journeys, including the first vertical test. The fixture
     backend needs a "commit but lose the append acknowledgement" mode.
  4. Add the activation dialog.
- **Pitfalls found:**
  - Playwright's fixture/app ports (54329/4317) are hard-coded in many specs, so parallel worktrees
    collide. A run started while another worktree's servers are up fails at start-up and can't mix
    results. Wait for the ports, or make them configurable everywhere.
  - In Node, `BroadcastChannel` must be `unref()`'d or Vitest hangs. `fake-indexeddb` needs
    `databases` stubbed when wrapping `open`.
  - `durability: 'strict'` is accepted by Chromium and `fake-indexeddb`.
  - On the WIP branch, a page that opens storage before activation stays at version 1. A
    `versionchange` from the same release's activation retires other tabs, just like a newer
    release would.
  - A probe that opens the database at a higher version fires `versionchange` and retires
    compatibility tabs. Read the version with `indexedDB.databases()` instead of opening it.

## Gate 1 local implementation, 2026-10-08

The reviewed implementation opens an authenticated version-2 journal from key preparation and
restores History and ChatSession before admitting chat work. New profiles start at version 2.
Existing version-1 profiles require a person's acknowledgement that they finished or copied work
and closed other tabs; deferring leaves version 1 and its tab-only behavior intact. Cooperative
messages cannot prove a noncooperating legacy tab has drained. There is no automatic reload,
plaintext fallback or exportable-key fallback.

The sealed head binds the exact backend origin, account, store incarnation, device and login
generation. Its child manifests and event hash chain detect missing/substituted records. Key,
reading-activity and journal writes compare the captured writer admission and synchronous
live/persisted login predicate in their IndexedDB transactions. Forget removes key material,
activity and journal data atomically, retaining only opaque retired-admission metadata with a
fresh incarnation so suspended callbacks cannot recreate the partition.

Draft checkpoints keep canonical text/branch revisions and submission receipts; delayed Send
consumes only its captured edit. Exact pending ciphertext, complete pull cursors and fresh-ID
replacement mappings are durable. Rebase validates the entire planned predecessor revision and
replacement closure before commit, including draft receipts and turn parents. A conflicting
descendant causes bounded replanning.

Composer and turn owner locks remain held through accepted writes. Reopening reads each
canonical checkpoint again after winning its owner lock. Recovering or removing a turn compares
the exact captured checkpoint inside its committing transaction; changes trigger a fresh read.
No reopening, sync, save retry or cleanup retry starts a paid request. Send remains online.
Unknown formats and private-record integrity failures preserve bytes and refuse private writes.

Local unit/controller and persistent Chromium evidence, known skips and failed-write limitations
are recorded in the [verification record](../verification/2026-10-08-browser-journal-gate1.md).
App navigation integration still needs to invoke the provided `flushCheckpoints()` boundary while
keeping failed edits reachable; this worktree retains the existing mounted-session navigation.
This gate does not provide a durable library, downloaded reader copies, cached cold-start key
authority or a service worker, and makes no cold offline-startup promise.

## Delivery gates and focused acceptance

1. **Durable private journal, after the compatibility checkpoint.** Implement persisted scope,
   format and writer admission, then draft checkpoints, exact event outbox, pull transactions,
   submission receipts, rotation and
   interrupted turns. Keep current online Send, library and navigation. Test a real persistent
   Chromium profile, not only a mocked IndexedDB implementation.
2. **Saved papers and library checkpoint.** Add v5 read/write parity, complete library snapshots,
   eligibility guards, explicit downloads and storage controls. Verify reopening without
   another hosted descriptor; protect unsent history from copy corruption and quota pressure.
3. **Cold offline startup.** Add cached recipient envelopes/local access and the bounded static
   shell. Only then advertise offline reading/history/drafting, or allow an offline question
   into the sealed outbox. Reconnection syncs it but never automatically buys an answer.

The first vertical test is: type → committed checkpoint → restart → submit → lose append
acknowledgement → restart → reconcile the exact event → explicitly request an answer → interrupt
→ reopen the partial answer and newer draft. Add two-tab edit/discard races, rotation with lost
acks and dependent events, forget/re-enroll with late callbacks, quota aborts, ambiguous commits,
missing children and unknown formats. None may become an empty successful journal.

The offline gate additionally requires a cold disconnected start showing equations, figures,
contents, selection and reading position with no API requests; blocked-copy/install/outage
races; dataset reset; invalid members; and failed shell installation. Preserve existing layout,
keyboard behavior, light/dark and accessibility during these journeys.

No new owner decision blocks the recommended sequence: recovery, explicit local copies and
local-only drafts follow established policy. **Safari remains a separate acceptance gate.**
Its non-extractable X25519 IndexedDB issue is still open; keep the actual key round-trip probe,
and do not infer support from Chromium. If usable Safari must precede these milestones, any
alternative key custody needs its own review and owner decision. This plan does not weaken
keys to get past it. Native iOS/Mac use their existing secure keystore.
[WebKit issue 312279](https://bugs.webkit.org/show_bug.cgi?id=312279), checked 2026-10-08.
