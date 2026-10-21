# Notes and snippets

Designed 2026-10-20 local / 2026-10-21 UTC. Proposal and interactive design prototype, now being built: see
[Server status](#server-status--blob-api-live-on-staging-2026-10-21-utc),
[Browser client status](#browser-client-status--implemented-locally-not-deployed-2026-10-21-utc) and
[Native client status](#native-client-status--iphone-ipad-and-mac-implemented-locally-not-released-2026-10-21-utc);
no client is released.
The owner requested the end-to-end experience and examination of the current app.
This document separates that direction from recommended details and implementation gates. Current released
clients remain TestFlight 77 and browser Pages `27c45ca0` as recorded in IMPLEMENTATION_STATUS.md.

## Implementation contract (Claude review, 2026-10-21 UTC) — supersedes conflicting details below

The owner asked for this proposal to be reviewed, improved and then built. The review keeps the product design and
its safety rules, and fixes the open choices so that the native, browser and server work can proceed in parallel
against one contract. Where the longer sections below differ, this section wins.

**Simplifications.**
- *Blob transport is one edge function, not a five-step reservation protocol.* Clients never touch Storage. The
  function is the only writer, so an idempotent `PUT` (same blob ID + same ciphertext digest = success; a different
  digest = conflict) replaces reserve/attempt/lease/commit. It checks length while receiving, enforces quotas in one
  SQL call before writing, writes with the service key and marks the row ready. A timeout on the client is resolved by
  repeating the same `PUT`. Downloads go through the same function, which meters monthly egress before reading.
- *Ordering is a counter, not an insertion object:* `counter` (integer ≥ 1) with ties broken by `entryID`.
- *Conflicts:* an entity with more than one head shows its deterministic winner (greatest event ID) with a
  "2 versions" badge; choosing a version writes a revision whose parents are every head. No silent merge of text.
- *Browser arbitrary-region capture* is attempted with a local, network-free rasterizer inside the reader frame. If it
  cannot render a region faithfully (MathML, fonts, images), the browser offers quote and whole figure/table capture
  only, and says so; it never falls back to screen sharing or a server renderer.

**Records.** Each record is a `PrivateEvent` of kind `note` whose `text` is one JSON object; `entityID` is the note's or
entry's ID; `createdAt` is set as for chats; no `documentID`/`paperReference` on the outer event. Creation has no
parents; a rename, comment edit or version choice names every current head of **that entity**; deletion is the
existing `tombstone` event for the entity. Records are recognised by `format == "gradstep-notes-v1"`; every other
`note` event (Library catalogs and anything older) is ignored by the Notes reducer, and Notes records must be ignored
by the catalog reducer and by every older client (tests prove both directions).

```text
Note  { format, record: "note", noteID, title (1–80 scalars, trimmed), createdAt (ms) }
Entry { format, record: "entry", entryID, noteID, kind: "region"|"quote"|"text", counter (≥1),
        capturedAt (ms), offsetMinutes, comment (≤16 KiB UTF-8, may be ""),
        source: null | { kind: "arxiv"|"local_pdf"|"document", title, authors[], sourceID, revision, url,
                         section, label, membershipID?, pdfSHA256?, page? },
        anchor: null | { manifestSHA256, rendererRevision, blockIDs[] (≤64), rects[[x,y,w,h]] (0–1, viewport-relative),
                         viewport [w,h,scale] | null, quote | null },
        quote: null | string (≤20 KiB),
        media: null | { full: Media, thumb?: Media } }
Media { blobID, key (base64, 32 bytes), sha256 (hex of the stored blob), bytes, type: "image/png"|"image/jpeg",
        width, height }
```

A revision repeats the whole record; only `title` (note) or `comment` (entry) may differ from the entity's first
record, which validators enforce. Unknown `format` values are kept and shown as "Update Gradstep to see this note";
malformed known records are skipped with a visible count, never dropped silently. Bounds: encoded record ≤48 KiB.

**Blob cryptography.** Fresh 32-byte key and 12-byte nonce per blob; AES-256-GCM; stored blob = nonce ‖ ciphertext ‖
tag; AAD = UTF-8 `science-reader/snippet-blob/v1\n{account UUID}\n{blob UUID}\n` with lowercase canonical UUIDs.
`sha256` is over the stored blob. Decrypting checks the digest, the tag, the media type's magic bytes and the decoded
dimensions against the record before display. Full image: PNG (JPEG only for photographic crops), longest edge
≤4,096 px, ≤6 MP, stored blob ≤2 MiB; thumbnail: JPEG, longest edge 480 px, ≤64 KiB. Fixtures:
`tests/fixtures/notes/notes-v1.json` (records, invalid and future records, and an exact encryption vector).

**Blob API** (`supabase/functions/note-assets`; bucket `note-assets`, private, `{account}/{blob}` paths, no client grants):
- `PUT /note-assets/{blobID}`, body = stored blob, header `x-content-sha256`. 200 `{state:"ready",bytes}`; 409 the ID
  exists with another digest; 413 over 2 MiB + 28 bytes; 429 `{code:"quota"}`; 401/403 as other functions.
- `GET /note-assets/{blobID}` → 200 bytes (`application/octet-stream`, `cache-control: private, no-store`); 404; 429
  when the monthly download allowance is used.
- Quotas, all server-side in one SQL function per call: per account 128 MiB and 4,000 objects stored, 512 MiB downloaded
  per month; per environment 512 MiB stored and 4 GiB downloaded per month. Pending rows count against quota. Usage
  appears on the admin spending page. Account deletion removes every `{account}/` object and row and verifies it.
- Same authentication and device/admission checks as the other user functions; nothing about notes is logged.

**Local durability.** A save commits the crop's stored blob, thumbnail, any new note and the entry together in the
account's encrypted local store (native: EncryptedStore; browser: the account's IndexedDB journal), then reports
"Saved". An entry event is uploaded only after its blobs return `ready`; uploads retry with the same IDs and bytes.
Text-only entries need no blob. Blobs are fetched on demand (thumbnail first) and cached encrypted.

**Navigation.** iPhone: Feed · Library · Paper · Chat · **Notes**; Settings is the last section of every top-right ⋯ menu
(Feed, Library, Paper, Chat, Notes) and opens the existing Settings as a sheet that returns to where you were. iPad,
Mac and browser add Notes to their existing destination lists; Mac keeps ⌘, for Settings.

**Capture entry points (v1).** Paper ⋯ › Draw snippet; selection menu › Add to note (quote); figure, table and
equation pages › Add to note (whole item, then optional adjust). Native HTML reader: `WKWebView.takeSnapshot` of the
chosen rect; local PDF: PDFKit page render of the rect. Notes ⋯/+: New note, Add text.

### Server status — blob API live on staging (2026-10-21 UTC)

Migration `202610210095_note_assets.sql` and the `note-assets` Edge function are deployed to staging
(`coxhjvqpflgxkleydati`); clients are separate work. Evidence: [implementation status](../IMPLEMENTATION_STATUS.md#notes-images-server--october-21-utc-staging-live).
The API as deployed (`{base}` = `https://<project>.supabase.co/functions/v1/note-assets`; both methods send
`Authorization: Bearer <access token>` and `apikey`, like every user function):

| Request | Responses (JSON errors are `{code}`, plus `retry_after` seconds and `Retry-After` when waiting helps) |
|---|---|
| `PUT {base}/{blobID}`, body = stored blob (28 B … 2 MiB + 28 B), `x-content-sha256: <hex>` | **200** `{state:"ready",bytes}` (also for a repeat of a ready object, which writes nothing) · **400** `digest_required` (missing/malformed header), `digest_mismatch` (body ≠ header), `invalid_blob` (< 28 B), `invalid_id` · **409** `conflict` (this account already has the ID with another digest or length) · **413** `too_large` · **429** `quota` (stored quota; no `retry_after`, objects stay until account deletion) or `quota` with `retry_after` (monthly read-back allowance, renews at the next UTC month) or `rate_limited` (60 s) · **401**/**403** as other functions · **503** `not_ready` (the stored bytes did not read back identically; repeat the same PUT) or `service_unavailable` (10 s) |
| `GET {base}/{blobID}` | **200** the bytes, `Content-Type: application/octet-stream`, `Content-Length`, `X-Content-SHA256` (CORS-exposed) · **404** `not_found` (no ready object of this ID for this account; pending objects and other accounts' objects look the same) · **429** `quota` + `retry_after` until the next UTC month, or `rate_limited` · **416** for `Range` · **503** `integrity_failed`/`asset_unavailable` (a charged read that failed; retry) |

Every response carries `Cache-Control: private, no-store`. Browser preflight allows `GET, PUT, OPTIONS` and the
`x-content-sha256` header for the shared reader origins. Blob IDs are per account: the same UUID under two accounts
is two objects (`{account}/{blob}`), never a conflict or a disclosure. Upper-case UUIDs/hex are accepted and
normalized to lower case. Downloads are charged in full before Storage is read; a failed read keeps its charge.

Behind it: one policy row (`app_private.note_asset_policy`, the single place for quotas) with the contract's limits,
plus two server-side bounds the contract did not list: each upload attempt's read-back is metered (256 MiB/account,
1 GiB/environment per month; a retry of a pending object is another read-back) and the shared request limiter allows
`note-upload` 300/hour/account (3,000 environment) and `note-download` 1,000/hour/account (10,000 environment).
Authentication is exactly the other functions' (Auth `getUser`, open account via `v1_account_context`, the request
limiter, not spending-suspended); no user-facing function checks device identity, so neither does this one — the
entry event carrying the key still needs device and management authority through `v1_append_event`. The bucket
(private, 2,097,180-byte limit, `application/octet-stream` only, no Storage policies) is provisioned and drift-checked
by `scripts/deploy-staging.py` from `infra/staging.json`, like every other bucket. Inventory: `app_private.note_assets`
(account, blob, stored-bytes SHA-256, length, `pending|ready`, attempt count/time), environment totals and monthly
transfer counters, all RLS deny-by-default and reachable only through service-role functions. Logs carry method,
status, error code, byte count and duration only.

Account deletion plans every inventoried object plus the `{account}/` folder. While a pending object's last write
began less than 10 minutes ago (above Edge's wall-clock limit) nothing is removed and `account-delete` answers
`complete:false`; the worker sweep finishes later. After removal the function lists the folder again and only an
empty listing lets `finish` delete the inventory rows and release capacity. The Cloud Run worker's sweep runs the
previous shared module until its next deploy: it removes every inventoried object but does not re-list. Ready
objects are included in `scripts/backup.py` checkpoints and counted by `restore-local.py`. Owner's Spending page
(admin) shows stored/pending bytes and this month's downloads and read-backs against the limits.

Supabase's gateway held an early refusal (401, 413, …) to an unread upload body over a few hundred KiB until a 504
after 160 s; the function therefore reads and discards (never buffers) up to 4 MiB of a refused body before
answering. A client that declares more than that may still see a gateway timeout instead of 413.

### Browser client status — implemented locally, not deployed (2026-10-21 UTC)

The browser (`apps/web`) implements the contract against the local fixture backend; it is **not deployed** and was
not exercised against the staging function. Evidence: [implementation status](../IMPLEMENTATION_STATUS.md#notes-and-snippets-browser--october-21-utc-local-not-deployed).

- **Records** (`lib/notes.ts`): the codec reads and writes `gradstep-notes-v1` in the fixture's field order, so every
  fixture record re-encodes byte for byte; the five invalid fixture records fail with their stated reasons; future
  `gradstep-notes-vN` records are counted and their note says "Update Gradstep"; any other `note` payload (catalogs,
  older notes) is ignored, and the catalog reducer ignores Notes records (both directions tested). The reducer orders
  entries by `(counter, entryID)`, keeps concurrent comments/titles as versions (winner = greatest event ID) until
  one is chosen with every head as parent, hides tombstoned entries/notes for good, shows entries whose note hasn't
  arrived as an incomplete note, and counts malformed records visibly (including revisions that change anything
  but the title/comment, and outer events with a document/paper/chat binding).
- **Blobs** (`lib/note-blob.ts`): AES-256-GCM with the contract AAD; the fixture vector matches byte for byte.
  Opening checks length, digest, tag and magic bytes; display additionally checks the image header and the decoded
  size against the record. Images are re-encoded on the device (PNG; JPEG only when the PNG would exceed 2 MiB;
  ≤4,096 px, ≤6 MP; JPEG thumbnail ≤480 px, ≤64 KiB), which strips metadata, and the composer shows those exact bytes.
- **Local durability** (`lib/journal.ts`, `lib/history.ts`, `lib/notes-store.ts`): a save commits sealed blob
  records, any new note and the entry in one IndexedDB transaction of the account's encrypted journal, then says
  Saved. Blob records sit outside the key range an older release counts (it rewrites the head's new `notes` manifest
  unchanged) and are removed with the browser's keys. The history's send gate uploads an entry's blobs (same IDs and
  bytes on every retry) before the entry event, and holds the entry and anything depending on it when an upload
  fails, while unrelated events (chats) still go. Unsynced crops are never evicted; downloaded or already-uploaded
  copies are an encrypted cache bounded at 96 MiB. Images are fetched on demand (thumbnail in the stream, full image
  in the zoom view), local copy first, and shown through in-memory `blob:` URLs revoked when the account's session
  retires; the app CSP therefore adds `img-src blob:` (the reader frame's CSP and sandbox are unchanged).
- **UI**: Notes is a destination (desktop: Library · Feed · Notes · Chats, with the list in the side panel beside the
  note; phone widths ≤640 px: Feed · Library · Paper · Chat · Notes at the bottom and the top-right account control
  becomes ⋯ with Settings). List with on-device search, counts, last edited and pending syncs; New, Rename, Delete
  (confirmation names the note and its entries); the stream with date separators, crops, quotes and writing; Edit
  comment, Open in paper and Delete snippet; "2 versions · Review"; full-size view with zoom; Add text. State labels
  follow the table above (keys-not-approved is the existing browser key setup, before any destination).
- **Capture**: selection › Add to note (a quote; no AI); a tapped equation, the figure page, the table page and the
  equation page › Add to note (a figure's own verified image when it has one asset; otherwise the element rendered
  from the paper); Paper ⋯ › Draw snippet (after Reader version details). The region is rasterized **inside the
  sandboxed reader frame**, locally and without network: the document is cloned with its stylesheets (media
  conditions resolved as they apply now), drawn from an SVG `foreignObject` data URL to a canvas, and the frame's
  own decoded pictures are painted over it (WebKit paints pictures inside an SVG image only after its first paint).
  Replies are bounded and bound to the open bundle. A probe disables Draw snippet with a message where the canvas
  can't be read back. Fidelity on real bundles passes in Chromium (1×, 2×), Firefox and WebKit (2×), light and dark.

Choices where the contract was open: UUIDs are written lowercase and read in either case; omitted nullable keys
read as null; a stored blob may be the 2 MiB image plus its 28 bytes (as the server's 413 bound), a thumbnail 64 KiB
plus 28; a thumbnail of either image type is read, JPEG is written; titles are trimmed with Swift's whitespace set
and limited to 80 scalars (no byte bound); counters ≤ 2³¹−1; `offsetMinutes` within ±1,440; source `sourceID`,
`revision` and `url` may be null (a non-arXiv paper); a deletion tombstone names the entity's current heads; a
region's anchor has its viewport rectangle and the covered blocks, an element capture has blocks only.

Not done in the browser: encrypted composer/comment drafts (Cancel after typing asks Discard or Keep editing, and an
unsaved comment does not survive a reload); the last destination is remembered for the session only (otherwise the
most recently edited note is preselected); "Keep both" when resolving versions; a New snippets jump; touch hold menus
and two-tap corners (Draw snippet is in Paper ⋯; keyboard users have Whole view, edge sliders and arrow keys on
corners); capture from a local PDF (the browser opens local PDFs outside the reader frame); Open in paper for a paper
not in this library (it says to add it). Real Safari, the hosted function and cross-platform (native ↔ browser)
records are untested; Playwright WebKit cannot persist the device keys, so the full journeys run in Chromium.

### Native client status — iPhone, iPad and Mac, implemented locally, not released (2026-10-21 UTC)

The native app (`apps/apple`) implements the contract; it is **not in TestFlight**. Its transport was exercised against
the staging function with a disposable account. Evidence: [implementation status](../IMPLEMENTATION_STATUS.md#notes-and-snippets-native--october-21-utc-local-not-released).

- **Records and blobs** (`ScienceReaderCore/Notes.swift`): the codec writes the fixture's key order with JavaScript's
  number and string formatting, so every fixture record and the encryption vector match byte for byte. Validation
  matches the browser's bounds (`apps/web/src/lib/notes.ts`) so neither client writes what the other refuses:
  `tests/fixtures/notes/cross-client-v1.json` holds six Swift-written records the browser codec re-encodes byte for
  byte and six browser-written records (null anchor identity, `0.30000000000000004`, `1e-7`, ±1,440-minute offsets,
  emoji/CJK titles) Swift re-encodes byte for byte. The reducer is the browser's: `(counter, entryID)` order, heads as
  versions with the greatest event ID shown, permanent tombstones, incomplete entries kept out of other notes, malformed
  and future records counted; non-Notes `note` events are ignored and the catalog reducer ignores Notes records.
- **Local durability** (`EncryptedStore`, store format 7): unsent blobs are sealed rows (`local_note_blobs`) listed in the
  authenticated metadata manifest with each held entry and the last-used note. `saveNoteEntry` commits blobs, a new note
  and the entry in one SQLite transaction; a failed write leaves nothing. `pending()` withholds an entry, and anything
  depending on it, until all its blobs are `ready`; chats and catalogs are never held. Holds follow key-rotation rebasing.
  Downloads and acknowledged uploads form an encrypted cache (192 MiB / 4,000 objects, oldest first); unsent captures
  (≤512 / 96 MiB) are never evicted. Opening refuses a missing unsent blob rather than dropping it.
- **Transport and sync** (`NoteAssets.swift`, `BackendNoteAssets`): `CloudSync` uploads pending blobs (same IDs and bytes
  on every retry) after catch-up and before pushing events; per-blob failures are shown in Notes and never stop chats.
  Responses map as deployed: 409 conflict, 413, 400 refusals, 429 `quota` (storage, or the month's downloads on GET),
  `rate_limited` and 503 as retryable; a GET body must match `X-Content-SHA256` and then its descriptor (digest, tag,
  magic bytes, decoded dimensions) before it is cached or shown. Images load on demand, thumbnail first.
- **Navigation**: iPhone tabs are Feed · Library · Paper · Chat · Notes. Every ⋯ menu (Feed and Listen, Library, Paper
  including its empty and error states, Chat in all states, Notes list and note) ends with Settings after Report this
  screen; on phone widths it opens as a sheet over the screen and Done returns there. The presentations Settings can open
  (sign-in, recovery, chats, diagrams, credits, reports, errors) are hosted inside that sheet while it is open. iPad and
  Mac add Notes to the wide view switch (Mac toolbar, View menu ⌘6) with the list beside the open note; their Settings
  gear/toolbar item and ⌘, are unchanged, and the menu section opens that same Settings and returns to the view.
- **Capture**: Paper ⋯ › Draw snippet, the selection menu's Draw snippet and Add to note (a quotation; separate from
  the paid chat actions), the Mac Paper menu (Draw Snippet, Add Selection to Note; no shortcuts), a figure or table
  page's Add to note (the whole item preselected, then adjustable), the equation page's Add to note (its rendering, on
  the card's background), and the local PDF reader's ⋯ › Draw snippet. Drawing freezes the page under an overlay (drag in
  either direction, nearest of four 44 pt corners, move inside, edge sliders, Whole page), Cancel/Escape restores it, and
  a size change asks for a new box. HTML: `WKWebView.takeSnapshot` of exactly the box at screen density, blocks/section/
  figure label read from the page DOM and checked against the bundle; PDF: PDFKit draws just that part of the page
  (rotation applied). The composer shows the encoded image that will be saved, preselects the last note (Quick notes on
  first use), offers New note and an optional comment, and returns to the page with "Saved to … · Open note".
- **Notes**: list (search over titles, writing, quotes and source titles on the device; +; rename and delete with the
  note's name and entry count; counts, last edited, pending syncs), the stream (date separators; crops with full-size
  pinch/double-tap zoom; quotations; writing; Edit comment; Open in paper at the captured passage on the same reader copy;
  Source details; Delete; "2 versions · Review" with Keep this version), Add text, and the state table's labels: locked
  (Unlock notes), signed out, waiting, image waiting to upload, upload failures in words, missing images with Retry.

Choices where the contract was open: the local PDF source carries `pdfSHA256` and a one-based `page` with no anchor; an
equation-page capture has its block and no rectangle; anchor rectangles are rounded to 1/10,000; tombstones have no
parents (the browser names the heads; each client reads both); a repeated Save of a committed capture is a no-op.

Not done natively: encrypted composer/comment drafts (Cancel after typing asks Discard or Keep editing); "Keep both";
a New snippets jump; two-tap corner placement and VoiceOver capture announcements beyond the area's label and size;
Open in paper for a local PDF source (it shows the source details); adjusting an equation-page capture. The physical
iPhone is paused; device-to-device sync (native ↔ browser through staging) has not been run end to end — only the
records (shared fixtures) and the blob service (live) are proven. Store format 7 cannot be opened by older builds.

## Product contract

A **note** is a named, ordered stream of snippets and the reader's own writing. A note can be a project spanning
many papers. A **snippet** is a deliberately captured region or selected passage, its immutable source details,
and optional editable commentary. One note owns each entry. Notes are independent of Library catalogs: moving
or removing a paper does not move or delete its notes.

Owner direction: create/manage encrypted notes; draw a box around paper content after a hold action; choose an
existing or new note; retain paper and capture date/time automatically; edit commentary; rename/delete/create
notes; sync using the existing device keys and Supabase. Replace the Settings tab with Notes and make Settings
available in every top-right menu. Those navigation changes were requested directly and need no repeated permission.

Recommended details, reviewable in the prototype:

- Five compact destinations in their current order: **Feed · Library · Paper · Chat · Notes**.
- One level of named notes; a project is simply a note named for that project. No new folder/tag system.
- Capture is **hold → Draw snippet → adjust rectangle → Add to note → Save**. Writing is optional.
- Also offer **Add selection to note** for a clean text quotation and **Add text** within a note. Neither invokes AI.
- Notes open as a list; a note opens as a chronological stream, oldest additions first, preserving reading position.
  A new capture appends. An explicit Open after saving jumps to that entry.
- Saving leaves the paper and its reading position in place. A small confirmation offers **Open note**.
- No new permanent side panel in the reader. Capture uses a sheet on iPhone and a bounded popover/sheet on larger
  screens; the existing paper/chat split remains intact.

## What the application actually has

Reviewed local source on 2026-10-20 local; these findings are source inspection, not new runtime certification.

| Existing implementation | Integration / missing work |
|---|---|
| `ReaderModel.swift` defines Feed, Library, Paper, Chat, Settings; `Views/RootView.swift` draws the five-item floating capsule | Replace the fifth item, add a Notes destination and account-owned state; present Settings without losing the originating route |
| Wide native navigation uses Feed, Library, Reader, Browse, General Chat; Mac uses its window toolbar | Add Notes to the wide destination selector; preserve Browse and the existing Reader split. Keep Mac's standard Settings command |
| `Views/DesignSystem.swift`, `Views/Chrome.swift`, `docs/DESIGN.md` define 16 pt margins, 44 pt touch controls, indigo actions, glass chrome and one rightmost ellipsis | Reuse those controls and spacing; create a Notes symbol in the existing brand icon system when implementing |
| `Mac/MacSupport.swift::ReaderWebView` adds selection actions to the system edit menu; `Views/PaperView.swift` validates selection against the bundle | Add note actions separately from paid `SelectionAction` chat dispatch; preserve Copy, existing explain/reference actions and equation menus |
| `Resources/reader-bridge.js` is shared with the sandboxed browser frame; touch double-tap opens Contents, Mac double-click selects | Add an explicit capture state and bounded messages; never globally replace selection/pan/double-tap handlers |
| Native HTML uses WKWebView; local PDF uses a separate `LocalPDFReaderView`/PDFKit presentation | Two capture adapters are required. An HTML-only implementation is not whole-reader completion |
| `PrivateState.swift` / browser `lib/events.ts` already admit `.note`, immutable causal revisions and permanent tombstones | Build a namespaced Notes codec and reducer. Existing `.note` records include Library catalog operations and must never appear as user notes |
| `EncryptedStore.swift`, native draft/account barriers, browser `lib/journal.ts`, `lib/history.ts` | Reuse encrypted journal, exact retry, pull cursor, account fencing and draft principles; extend local stores for attachment transactions |
| `LibraryCatalog.swift` / `lib/library-catalogs.ts` demonstrate old-reader-compatible JSON inside an encrypted note event | Useful codec precedent. Catalog's concurrent rename tie-break is unsuitable for personal writing: retain both text versions |
| `Crypto.swift`, `lib/wire.ts`, `DeviceKeys` and recovery/approval flows | Reuse account/key authority and frozen event encryption. Define/test a separate blob domain; never expose content keys to Storage |
| Migration 002 supplies `sync_events`; 009 supplies history limits; 058 adds event format 2 | Small Notes records can use existing transport. Images cannot be base64-packed into history |
| `DATA_MODEL.md` mentions planned `encrypted_blobs`, but no matching table/service exists in migrations or clients | Encrypted snippet media needs a real new inventory, API and private bucket; documentation is not evidence of implementation |
| Browser support capture uses `getDisplayMedia`; browser paper bundles are bounded in-memory caches | Do not reuse screen-sharing capture for the normal snippet gesture or claim cold-offline browser support |

Applicable existing contracts: [HTML-first reader](HTML_FIRST_READER.md), [Privacy and sync](PRIVACY_AND_SYNC.md),
[encrypted wire](ENCRYPTED_WIRE_FORMAT.md), [data model](DATA_MODEL.md), [catalogs](LIBRARY_CATALOGS.md),
[browser durability](BROWSER_OFFLINE_STORAGE.md), [asset accounting](ASSET_SPENDING.md), [testing](../TESTING.md).
Historical server PDF/OCR descriptions in those documents do not override the device-only boundary.

## Capture, step by step

### Entry and gesture arbitration

Over text, a normal hold still starts native selection immediately. Keep **Select / Select text** as the default
behavior and add **Draw snippet** to the contextual actions. Avoid a mandatory chooser before every text selection.
The selection menu also offers **Add selection to note**. Over noninteractive image/blank paper content, a hold
can offer Draw snippet without manufacturing a text selection. Paper's **… → Draw snippet** is always an accessible,
discoverable entry. Figure/equation/table views offer **Add to note** for their whole item, followed by Adjust crop.

Links, references, equations and figure controls retain their current tap actions. A capture gesture must not win
against an already recognized text selection, page pan or system gesture. Outside capture mode, touch double-tap
still opens Contents and Mac double-click still selects. Mac/iPad pointer users get a contextual Draw snippet
action and the same menu entry; no global keyboard shortcut is assigned until existing bindings are audited.

### Drawing

Entering capture fixes the current paper viewport and dismisses its transient menus. Show **Cancel · Draw snippet**
and a concise hint, then let a single drag create a rectangle in either direction. Dim outside the rectangle.
Release exposes four draggable corner handles and **Use snippet**; dragging inside moves the box. Use 44 pt
effective handle targets, keep the visible marks small, and prevent overlap when the box is very small. A tiny
or empty rectangle cannot advance. Cancel and Escape restore the reading/selection state.

The first version captures one visible region, not a stitched scrolling screenshot. Users scroll/zoom first.
While adjusting, the viewport is frozen; any rotation, reflow, font change or renderer replacement invalidates
the geometry and asks for a new box. Keep a recoverable commentary draft if one exists. Do not silently recrop a
different location. Large content can be captured from the existing figure/table view or as multiple snippets.

Keyboard and assistive technology can select a whole paragraph/figure/table/equation, then adjust each edge with
labeled controls; freehand dragging is never the only path. Native VoiceOver announces capture state and dimensions.
Two-tap corner placement is a further touch alternative to validate. Ink drawing, arbitrary lasso and annotation
on top of the image are later features.

### Add to note

The composer shows the actual crop first, **Note** destination, **Your comment (optional)**, and one quiet source
line (paper · section/figure or PDF page · capture date/time). The source line opens full details. It is not editable
commentary. Users can go back to adjust before saving.

The last successfully used destination on this device is preselected and plainly visible. Switching opens recent
notes, local search and **New note**. First use offers **Quick notes**, created only when Save commits, or an inline
new name. A new note and its first snippet commit together. Cancel creates neither an empty note nor an entry.
Remember the destination in account-scoped encrypted local preferences, not a global plaintext preference.

Save acknowledges a durable **local** commit, then returns to the paper. It does not wait for a network upload.
Show `Saved to [name]` with Open note; offline, add `Waiting to sync`. The queue owns accepted work even if the
reader changes tabs. Repeated Save taps, retry and app restart preserve one operation/entry identity. A failed
local write keeps the crop/comment/destination visible and never says Saved. Cancel after typing asks to keep
the encrypted draft or discard it; merely dismissing the keyboard is not cancellation.

The source PDF/HTML bundle stays on the device. Only the deliberately chosen crop, bounded quotation/context and
the reader's writing enter encrypted sync. This is a new, explicit user-created derivative; it does not re-enable
whole-PDF upload, server PDF processing, Mathpix or automatic background paper capture. Existing public-launch
content-rights review remains applicable; the prototype makes no rights clearance claim.

## Notes and navigation

**Notes list:** matching header, local Search notes, a create (+) control, rightmost ellipsis, and quiet rows with
title, entry count, last edited date and short user-written preview. Search names, comments and available quoted
text in memory on the device. Do not index private text in Supabase search or reuse service-visible Library tags.
Sort the list by recent activity with deterministic identity tie-breaks; that is presentation, not conflict resolution.
No automatic AI title, embeddings, summary, OCR or credits are needed.

**Note detail:** back to Notes, title, add (+), ellipsis; then a continuous readable stream with date separators.
Each entry contains crop or quoted text, the reader's commentary, and a small source/date line. **Edit comment**,
**Open in paper**, and **Delete snippet** are available through its menu. Tapping a crop opens a full-resolution
zoom view. Keep images aspect-correct and give tall ones a bounded preview with an explicit expand action.
Add text creates a normal entry without a fabricated paper/source. Empty notes invite writing or capturing in Paper.

Comment editing keeps a recoverable encrypted local draft. **Done** commits a new causal revision and announces
Saved only after local persistence. Navigation can checkpoint unfinished work without publishing each keystroke.
Opening Settings and returning must restore the draft, note, scroll anchor and originating destination.

**Management:** create, rename and delete from the Notes list and note menu. Duplicate names are allowed; identity
is a UUID. Deletion confirms the note name and entry count, then writes a tombstone. Copy says removal propagates
when devices sync; it does not promise immediate erasure of historical ciphertext. Existing encrypted revision
retention follows chat until account deletion. Library removal does not cascade into notes. Move/copy entries,
manual reordering, folders, sharing, export and AI over notes are follow-ups, not hidden prerequisites for v1.

**Settings everywhere:** append a shared Settings menu section to Feed (including Listen), Library, Paper (including
its empty/error state), Chat (paper/general/empty), Notes list and detail. Keep Report this screen accessible;
use the same relative order everywhere. Reuse the existing Settings content in a full-height navigable presentation
with Done/back to the originating screen. Centralize presentation to avoid competing sheets. On wide iPad/Mac
and browser, add Notes to their existing destination system instead of forcing phone tabs. The Notes workspace
uses list + detail when space allows; it never replaces the reader's chat pane. Mac's Settings command remains.

**Accessibility/style:** use the existing indigo, neutral surfaces, one amber detail in a brand Notes glyph, Dynamic
Type, readable column, reduced-motion/transparency alternatives and 44 pt targets. Use text with sync/error icons,
not color alone. Preserve the existing keyboard/tab-bar behavior and podcast mini-player reserve. New-item arrivals
do not take scroll ownership; offer a New snippets jump while reading older entries.

| State | Reader-facing behavior |
|---|---|
| Signed in, keys not approved | Notes stays a destination with Unlock notes using the existing device approval/recovery flow; no empty-note claim or new unprotected store |
| Durable local save, no connection | Saved on this device · Waiting to sync; keep reading and show pending count in Notes/Account |
| Metadata and all referenced uploads acknowledged | Synced means stored for the account, not that every device is online or has downloaded the image |
| Failed upload, quota or expired session | Preserve the local entry/crop and explain Retry, storage pause or sign-in; unrelated already available notes remain readable |
| Descriptor arrived, image not downloaded | Keep commentary/source visible with an image placeholder and Retry; never substitute another crop |
| Concurrent commentary/rename | Two versions · Review; preserve both until an explicit resolution |
| Local disk/IDB write failed | Keep the editor and draft; report Couldn’t save on this device, with no Saved or Synced label |

The prototype includes a visible Draw snippet shortcut beside Contents to make the new action easy to explore.
Its production placement is a proposal: the contextual action and ellipsis entry are the required paths; preserve
existing reader control space and make a concrete layout review before adding a persistent shortcut there.

## Source provenance and reopening

All of the following is inside the encrypted entry payload:

| Common | Structured HTML | Local PDF |
|---|---|---|
| Account-independent random entry/note IDs; captured UTC milliseconds + original offset; paper title/authors snapshot; exact source ID/revision/link when known; original capture time distinct from edit time | Source membership or legacy document identity; exact manifest SHA-256 and renderer revision; intersected block IDs; available quote/prefix/suffix; element-relative rects; capture viewport/scale and layout signature | Local paper UUID; PDF SHA-256; page index (one-based display); normalized crop in the unrotated crop-box coordinate system; crop box, rotation and render scale |

Never guess a PDF page for HTML, invent OCR text for an image, or send filenames/private titles as object paths.
Store normalized finite rectangles and bounded coordinates; keep the immutable crop as the visual source of truth.
An arbitrary region can span several blocks, so one `TextAnchor` is not sufficient. A new private capture descriptor
contains its own anchors; existing chat anchor decoding stays unchanged.

On the original matching layout, Open in paper can outline the exact region. After ordinary text reflow, resolve
the same source blocks/quote and label any location that can only be approximate. A different manifest/adapter
does not inherit the old pixel rectangle. Prefer the retained original bundle; otherwise offer the same source
revision with explicit location uncertainty. Never match by title, ordinal block or a newer paper revision alone.

The snippet and commentary remain readable on a second approved device without the full paper. Open in paper can
ask to download that exact public source on that device, or to reselect the local PDF and validate its digest.
No source availability or library membership is fabricated. The crop does not disappear when a paper is removed.

## Encrypted records and merge rules

Use existing `PrivateEvent.kind = note` and a bounded JSON string in `text`. Proposed namespace:
`gradstep-notes-v1`. Distinguish `record: note` and `record: entry`; allocate independent random entity IDs.
Use normal `.tombstone` records for deletion. Do not add a required enum case that stops old clients' sync.

Proposed payload shapes (descriptive, not a shipped codec):

```text
Note { format, record: note, operationID, title, createdAt }
Entry { format, record: entry, operationID, noteID, kind: region|quote|text,
        insertion: { counter, entryID }, capturedAt, captureOffsetMinutes,
        source?, capture?, quote?, media?, comment }
Media { full: { blobID, key, cipherSHA256, plainSHA256, byteCount, mediaType, width, height },
        thumbnail?: { same descriptor fields } }
```

The outer event's entityID is the logical note/entry ID. Operation IDs and insertion IDs survive content-key
rotation, unlike envelope IDs. Source bindings live inside the Notes payload; an outer legacy document binding
must not turn a source-only/local PDF into a fictitious server document. Existing format-1 note wrappers can carry
this bounded payload without modifying the wire; validate that against frozen Swift/web readers before emitting it.

Note rename revisions and entry-comment revisions name all observed heads of **their own entity** as parents.
Creation can additionally depend on the new note root in an atomic batch; the Notes reducer validates typed
dependencies, entity invariants and missing ancestry. Comment revisions cannot rewrite capture geometry, pixels,
provenance, note ownership, original timestamp or insertion identity. Cropping after Save would create a new entry.

- Independent entry additions/edits commute; no whole-note array is rewritten.
- New insertion counter = one greater than the greatest known counter in this note, including removed entries.
  Sort by `(counter, immutable entry UUID)`; reject overflow and invalid counters. Concurrent appends are retained
  in deterministic order. Editing never changes the order. Device clocks and transport arrival never resolve edits.
- Concurrent comments or renames retain all surviving causal heads. Show `Two versions · Review`; Keep this version,
  Keep both, or an explicitly edited merge writes a resolution depending on every observed head. A late unseen head
  remains a conflict. Do not copy the catalog reducer's silent text tie-break into personal notes.
- A note tombstone hides its entries; an entry tombstone defeats every stale revision. Before uploading pending
  local work, catch up and reconcile deletion. Preserve affected unsent writing/crops as recoverable local drafts;
  Copy to a new note uses new IDs. Never recreate the deleted identity or silently choose a different destination.
- A missing note root is a loading/incomplete state, never a reason to assign the entry to Quick notes. Unknown
  Notes payload versions stay encrypted and intact; indicate Update required for that note while unrelated chats
  and known notes remain usable. Malformed known payloads are quarantined visibly, not silently dropped/reset.
- Namespace filtering excludes Library catalogs and every other technical `.note` record. Old clients may carry
  opaque Notes records but cannot edit or display them. Both directions need compatibility fixtures.

Proposed validation bounds: title 80 Unicode scalars / 240 UTF-8 bytes; comment 16 KiB; quote 20 KiB; context 1 KiB
each side; at most 64 intersected source blocks; total encoded Notes record 48 KiB; existing 100-parent ceiling.
An over-limit operation remains a draft with an actionable explanation, without truncating content. Client event
capacity remains shared with chats/catalogs (browser history currently 20,000 events / 64 MiB, outbox 128 / 8 MiB).
Do not advertise unlimited notes or increase those caps implicitly. Large-history paging is a separate gate.

## Media cryptography and local durability

Create the image and thumbnail on the device. Encode PNG for text/math by default, with measured alternative JPEG
for photographic regions only; preview the actual encoded result and never silently discard detail to meet a cap.
Proposed limits: main ciphertext ≤2 MiB, thumbnail ≤64 KiB, longest decoded edge ≤4,096 px, total ≤6 megapixels.
Strip metadata. Source image bytes, title, capture rectangle and plaintext hashes stay out of cloud indexes/logs.

Each immutable object has a fresh random 256-bit content key and random opaque blob UUID. AES-256-GCM uses a fresh
96-bit nonce; authenticate `science-reader/snippet-blob/v1\n{account}\n{blob}\n` with canonical UUIDs and final newline.
Store nonce+ciphertext+tag. The key is only in the encrypted Media descriptor, protected by existing account epoch
keys. Thumbnails get independent keys/IDs/nonces. No cross-account deduplication or server image transformation.
Retries reuse the exact object ID and ciphertext; different bytes require a new ID. Ciphertext SHA-256 checks
transport; successful AEAD plus bounds/decoded type and dimensions validate content on the receiving device.
The server cannot validate image semantics inside ciphertext; clients must defend against malformed content.

Extend the account's encrypted local journal with blob and snippet-draft records, dependency receipts, capacity
and integrity checks. A local transaction commits the image, thumbnail, new note if needed, entry, draft consumption
and upload intent together. Native can use dedicated SQLite blob rows; browser uses stores in the same IDB
transaction after encryption is prepared. Include children in the authenticated manifest. Do not acknowledge an
event with a missing file or keep private crops as plaintext temp files. If filesystem staging is chosen instead,
design and test its write/fsync/rename/reference protocol before substituting it for this atomic model.

Protect and exclude native local stores from backup as today; retain per-account sign-out semantics and drain
accepted writes. Browser keys remain non-extractable, account stores fenced and encrypted; storage eviction is a
real limitation. Loaded-session offline capture and reload recovery are separate from cold-offline app startup,
which is not currently qualified. No exportable-key/plaintext fallback. Display object URLs exist only in memory
and are revoked on retirement. Bound decoded image caches and release canvas/snapshot buffers promptly.

Key recovery uses the existing approved-device/recovery-code bundle. Event rebasing preserves the Media descriptor
and its random object key; it does not upload another image just because the event envelope changes. New media
keys are distributed only through current-authority events. Revocation cannot erase content/keys a device already
learned. Rotation/revocation/restore claims require exact new-blob fixtures and lifecycle evidence.

## Supabase layout and transport — design before migration

Use a dedicated **private** bucket, proposed `note-assets`, with only opaque ciphertext objects served as
`application/octet-stream`. Proposed object path: `{account UUID}/{blob UUID}`. No note ID, paper ID, title or
filename in paths. A new inventory record holds owner, blob ID, request ID, ciphertext digest/length, state,
upload attempt/lease generation, retention state and operational timestamps. Composite ownership constraints and
deny-by-default grants/RLS apply. Account authentication alone is insufficient: upload/download APIs additionally
check the active approved device and management authority through the existing keyring contract.

The service can see owner/device, opaque IDs, byte counts, request/commit timing and encrypted event traffic. It
cannot read note titles, comments, paper bindings, capture dates inside payloads, images or object keys. Existing
library metadata already has its own disclosed boundary. Stored encryption is not hidden access-pattern metadata.

Supabase private buckets apply RLS to reads/writes; that is access control, not client encryption. See
[Supabase buckets](https://supabase.com/docs/guides/storage/buckets/fundamentals) and
[access control](https://supabase.com/docs/guides/storage/security/access-control). For this design, ordinary clients
have no direct object list/upload/download grants: bounded service endpoints enforce authority and quotas, then
use service credentials server-side. Do not issue replayable signed URLs and call their issuance an egress limit.

Proposed contracts, named provisionally:

1. **Reserve upload** with stable request ID, blob ID, ciphertext digest and exact bytes. Transactional per-account
   and environment reservations count pending, uncertain and committed objects. Conflicting retries fail.
2. **Upload ciphertext** through a bounded single-use attempt. Enforce length before/while receiving; record the
   attempt before Storage I/O; refuse upsert. Validate stored ciphertext digest/length before marking ready.
   A timeout is uncertain; replay/status reconciles that same object. Never release its hold on a timer alone.
3. **Upload the ordinary encrypted entry event** only when all its objects are verified ready. The existing durable
   event outbox retains that dependency. New-note root can sync first; another device sees a complete entry only
   after its blobs are ready. Text-only entries need no blob service. A failed media job must not indefinitely block
   unrelated chats: extend the outbox scheduler without violating causal/event cursor rules.
4. **Pull events** through existing bounded cursor catch-up. Download thumbnails on demand, full image on opening
   or explicit offline retention. A failed/missing image keeps source/comment visible with Retry; never claim the
   original is downloaded because its thumbnail arrived. Commit an event/cursor independently of a failed optional
   media download; retain the descriptor and its fetch task.
5. **Download ciphertext** with an account/device-bound, short-lived single-use grant; redeem and reserve worst-case
   egress before reading Storage, just like the reviewed bounded paper delivery pattern. Repeated downloads need
   new accounted grants. No public CDN or unauthenticated object reads; operational logs contain no bodies/keys.

There is no distributed atomic transaction between Storage and Postgres. These states and exact replay bridge it.
For v1, verified encrypted objects remain inventoried until account deletion, even if their eventual event upload
fails or their entry is removed. This intentionally avoids unsafe server garbage collection: the server cannot
read encrypted references. Cancelled/unverified objects require fenced reconciliation and confirmed deletion
before releasing capacity; late writes must be drained. Future per-note permanent purge/reference accounting is a
separate protocol, with its metadata disclosure stated explicitly.

Account deletion first closes all admission, cancels/fences uploads, then purges every inventoried note object
including uncertain attempts, deletes history/key material and completes only after object removal is verified.
Extend existing resumable deletion and backup retention contracts. Do not infer complete deletion from a truncated
Storage listing. Ordinary note deletion uses the permanent encrypted tombstone and retains historical ciphertext
as existing chat does; support/admin has no plaintext preview capability.

## Capacity and the $100 budget

No new fixed commitment, provider usage or cloud reservation was incurred by this design/prototype. It requires no
AI service. The private-beta total stays **$100/month** independently of TextBrain. Prototype caps are engineering
proposals, not a provisioned allowance or statement of current cloud headroom.

Start with server-enforced media ceilings of 128 MiB/account and a 512 MiB pilot allocation **within** the existing
global asset budget; add byte/object/attempt/rate limits and monthly download ceilings (proposed 128 MiB/account,
2 GiB/environment for this feature). Do not enable admission until accounting allocates verified available capacity.
New counters must include outstanding and uncertain reservations and share the global storage/transfer constraints.
At capacity, existing notes stay readable from cache, queued captures stay local, and the UI offers a specific
storage/sync explanation. No destructive local eviction of unsynced crops and no client-only spending cap.

Planning example, not measured usage: 10 testers ×100 snippets ×150 KiB combined image/thumbnail ≈146.5 MiB;
one additional full copy/device adds that much download traffic. At 100 testers ×200 snippets the same assumption
is ≈2.86 GiB, beyond the proposed pilot allocation. Measure real crop sizes and fetch frequency before expansion.
Maintain fixed commitments, actual bytes/vendor expense, outstanding/uncertain reservations and a forecast in the
existing private spending dashboard. Record relevant current vendor rates before converting these units to dollars;
do not claim unused bundled quota or a guaranteed zero-cost feature without that evidence.

## Platform feasibility and delivery gates

**Apple capture spike:** WKWebView provides a native snapshot API with a configurable rectangle; use the paper view
only and transform its coordinates explicitly. Validate after-layout capture, scale, safe areas, scrolling/zoom,
MathML, images, dark mode and removal of crop overlays without moving the document. PDFKit needs its own
page-space clipping/render path, rotation tests and page-boundary behavior. Reference:
[Apple WKSnapshotConfiguration](https://developer.apple.com/documentation/webkit/wksnapshotconfiguration).
API availability is not evidence that Gradstep's particular reader/crop interaction works.

**Browser capture spike:** ordinary page code has no equivalent general WKWebView snapshot call. Reusing support's
screen-sharing chooser would interrupt every capture; browsers require fresh user permission for `getDisplayMedia`
([MDN](https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getDisplayMedia)). Evaluate a strictly local,
network-disabled rasterizer over the verified reader's inert content, fonts, MathML and embedded assets, under
the actual sandbox/CSP, in Chromium/Firefox/WebKit. Coordinate/geometry messages need session/load nonce checks,
source frame validation, finite bounds and exact bundle identity. Do not weaken the reader CSP to make capture work.
Text quotations and crops of already decoded image/canvas content are simpler, but do not count as arbitrary-region
parity. If the local rasterizer cannot faithfully represent a region, retain the source and report capture unavailable;
browser arbitrary capture remains unqualified until a concrete alternative is reviewed. No server screenshot renderer,
PDF upload or full-screen capture fallback is silently introduced.

| Delivery | Completion evidence required |
|---|---|
| 1. Interaction/geometry | Reviewed phone and wide layouts; actual native HTML/PDF capture; browser local-raster feasibility; default selection/Contents/navigation preserved |
| 2. Records/local save | Frozen Swift/web Notes codecs; deterministic replay, concurrent additions/comments, stale deletion, key-rotation ID replacement; atomic new-note/crop/draft commit with disk-full/crash/account-switch cases |
| 3. Encrypted media transport | Designed then migrated inventory/bucket/API; two-account denial; revoked-device refusal; duplicate and uncertain uploads; concurrency limits/egress; tamper/oversize/decoded-bomb refusal; deletion cleanup |
| 4. Full note workflow | Create/rename/search/delete; optional comment/edit; quotation and text entry; original timestamp; source reopen/mismatch/missing-PDF handling; locked/recovery/offline/pending/error states |
| 5. Cross-device acceptance | Device A offline save → reconnect → Device B approved recovery and crop decrypt; missed realtime; conflicting offline edits; no resurrection; account deletion; restored DB plus ciphertext objects |
| 6. Release | Focused browser/native journeys, required current import gate for shared root/model changes, screenshot review, exact TestFlight/browser readback and updated status. Physical iPhone remains paused |

Use `npm test` for routine implementation checks. Geometry/browser, Simulator, database, hosted and real-paper
checks are explicit affected gates under TESTING.md, not an automatic full-suite rerun. The mockup uses synthetic
content and session-memory interactions; it verifies neither production encryption nor cross-device sync.

## Prototype and review scope

`docs/prototypes/notes-snippets.html` is an in-conversation interactive mobile design. It demonstrates the Notes
list/stream, drawing and adjusting a region, destination/new-note choice, optional commentary, editing, renaming,
deletion and Settings entry from five destinations. Its sample chart and notes are invented demonstration data.
Theme follows the host; design controls allow review of capture availability and sync/source states. In the preview,
changes are session-only, and sync labels are simulated. Wide/native platform adaptation and OS gesture fidelity
remain the implementation gates above; the mockup must never be reported as a working E2EE feature.

Local prototype review completed 2026-10-21 05:40:54 UTC. Its seven interaction/layout groups pass in Chromium,
including 320/390/736 px light/dark checks, and screenshots were visually reviewed. Exact scope, hash and evidence
are recorded in [implementation status](../IMPLEMENTATION_STATUS.md#notes-and-snippets--october-20-local--october-21-utc-designprototype-only).
The prototype clips authored SVG sample content; it does not implement or qualify raster capture from the real reader.
