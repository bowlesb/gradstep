# Browser podcast request recovery — 2026-10-08

Local client work only; no hosted call, backend migration, deployment or provider use. The standalone
fixture serves labeled synthetic tones. This extends the reviewed podcast client and follows the
actual `podcast-v1` server contract (`921562f`), including the `reuse` result from Start and Status when
an episode becomes ready after its quote. Server spending admission remains authoritative.

## Request identity and storage

Before each explicit Start, the client synchronously writes and reads back an opaque recovery hint in
`sessionStorage`. Its key includes the configured backend origin, environment, account and login lifetime.
Strict version-1 records contain only item/request/quote UUIDs and quote expiry. The displayed recovery
quote is reconstructed from the already validated fixed v1 credit, provider, duration and consent contract;
no paper title, transcript, chat, free server text, bearer token or key material is persisted here.

The ledger is bounded at 20 unresolved requests and 16 KiB. It never evicts unresolved work. Unsupported
formats, malformed records, full capacity, denied storage and failed read-back refuse Start. The exact
record survives sheet close, reader component unmount and reload. Auth retirement clears only its captured
lifetime, including reload followed by sign-out before opening the sheet. This is a per-tab session recovery
hint, not the encrypted chat journal, an offline queue, a durable disk guarantee or cross-device state.
Closing the tab or clearing site data can remove it; there is no automatic paid replay.

Opening the sheet checks current capabilities and, if a hint exists, reads the status of that exact request.
A missing paper job, missing status, transport failure or expired quote after an ambiguous attempt cannot
replace the old identity. Retry is explicit and sends the original request/quote/consent tuple. A positive
same-ID job result, a reuse result followed by a validated ready release, or an explicit expiry refusal of
the first uninterrupted Start reconciles the hint. A failed release read retains it. A reused release offers
Play; it does not automatically download, cancel or start anything.

## Navigation

The dock accepts an asynchronous evidence result: true means navigation won, false means the paper is
absent, and null means navigation was superseded. It waits before folding or showing Add, and ignores a
late result after auth retirement or a change of episode. Root-owned App integration installs the passage
only when its checkpoint-draining navigation wins. Reading/chat navigation does not start podcast work.

## Validation

- Focused contract and recovery tests: **36 pass**, including exact receipts, malformed state,
  capacity without eviction, write/read-back failure, auth retirement and start/status reuse decoding.
- Full unit suite: **281 tests / 23 files pass**. Typecheck and production build pass (the existing large diagram-chunk warning remains).
- **23 standalone Chromium journeys accepted**: the full run passed 22; one test changed a fixture status while the reopen read was still in flight, so the correct successful reconciliation removed Retry before the test could click it. Waiting for the intentionally absent read to settle fixed the test, and its targeted rerun passed. Production source was unchanged between those two runs.
- The focused suite includes a same-task double-click regression proving one Start dispatch. Existing playback, checksum/tampering, revocation, two-tab resume, explicit consent/cancel and phone layout cases also pass. The 390 × 844 consent screenshot was inspected; the amount, providers, privacy disclosure and explicit action remain readable.
- Browser scenarios use the production CSP and isolated loopback fixture/app ports 54389 / 4377.
  They cover close-before-admission, a lost response across close/unmount/reload, exact explicit retry,
  late Start/Status reuse, failed reuse lookup, quota refusal, corrupted storage, uncertain expiry,
  explicit cancellation, auth retirement, and delayed/superseded evidence callbacks.

No real audio quality, hosted capability enablement, Safari durable-key storage, physical-phone behavior or
cross-device listening history is claimed. The retained same-ID policy deliberately leaves an ambiguous
expired request unresolved if the server cannot supply a positive receipt; a discovery miss is not proof
that paid admission did not occur.
