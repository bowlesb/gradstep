# Device-local papers and reader bundles

Status: design adopted with migration 051 (2026-10-09); the first native local-store checkpoint is implemented locally
(2026-10-09). This is the delivery
model for an arXiv version whose exact submitted license does not authorize our
server to retain or serve the PDF or derived files. It deliberately keeps
metadata and account state synchronized while keeping paper bytes on approved
devices.

## What the server stores

For every source-only import, Supabase may store:

- the normalized arXiv identifier and requested/versioned revision;
- title, authors, abstract, categories, publication dates and the observed
  license URL;
- the versioned abstract URL (`https://arxiv.org/abs/<id>v<revision>`);
- encrypted account metadata such as tags, archive state and chat events; and
- bounded operational state (`source_only`, `license_unverified`, timestamps,
  retries and deletion tombstones).

It does not store the PDF, a PDF hash as a download authorization, Mathpix
input/output, images, reader HTML, audio, podcast script, or a server-side
reader artifact for that import. A hash may be computed transiently on a
device for local integrity and AirDrop identity; it is not a permission grant
and is not uploaded as a paper asset.

The durable `pipeline_papers.rights_mode` is the audit field. `shared` is only
the exact CC BY 4.0/CC0 evidence path, `private` is a web/reader-upload or
separately evidenced private path, `source_only` is device retrieval, and
`legacy_private` marks pre-051 arXiv conversions that need an operator rights
review. The worker chooses this mode before download admission, so a source
only row cannot accidentally reach Storage, OCR funding, or rendering.

## Device flow

1. The user adds a paper. The server resolves metadata and the exact revision,
   then returns `source_only` plus the versioned source URL.
2. The device opens the source link or explicitly chooses **Download on this
   device**. The native client fetches the versioned arXiv page and follows its
   declared PDF link (or the equivalent versioned PDF URL) with the existing
   bounded HTTPS validator, checks the PDF header and size, and writes the bytes
   to an encrypted local document store. It does not upload the bytes to
   Supabase and does not use the server's PDF upload queue.
3. The local document record is bound to `(account, source ID, exact
   revision, sha256)` and to the local-store key. A later arXiv revision is a
   new record; it never silently replaces the paper the reader was using.
4. When a rights-cleared reader bundle exists locally, the existing bundle
   verifier and `ReaderBundleCoordinator` install it beside the encrypted
   original. If only the original PDF exists, the native PDF viewer offers
   **Open PDF** on that device rather than pretending the structured reader is
   ready.
5. Tags, reading state and encrypted chats continue to sync through the normal
   account protocol. They contain identifiers and encrypted content, never the
   PDF or unencrypted extracted text.

The native checkpoint uses a migration-free, file-backed `DevicePaperStore`
beside the encrypted metadata store. Keeping large PDF ciphertext out of the
SQLite journal avoids inflating sync checkpoints and WAL files while retaining
the same account key and retirement fence. It does not overload the cloud
library item (which requires a server document) or the existing temporary
`PDFUploadQueue`, whose purpose is to upload a user-supplied PDF. The store
has explicit open, delete, capacity and account-retirement operations, an
authenticated manifest, atomic writes, orphan pruning, and a plaintext hash
bound to the exact source revision. Its current native action is deliberately
limited to direct source retrieval and local PDF viewing; reader-bundle
installation, transfer, and local Mathpix processing remain separate gates.

## Approved-device transfer

AirDrop is a local transfer of an encrypted package, not a second cloud copy.
The sending device creates a bounded package containing the local paper
record, encrypted PDF, and any verified reader bundle. It signs the package
with the existing device key and wraps its content key to the approved
recipient device. The recipient verifies account, source ID, exact revision,
manifest and signature before importing into its own local store. A package
never contains a reusable server token, Mathpix credential, or plaintext chat.

The transfer UI must make the rights boundary clear: **Transfer to an approved
device**. It must not be presented as public sharing, and it must not make a
source-only paper appear in another account's library.

## Mathpix boundary

The current Mathpix integration uses a server-held credential and therefore
cannot be called directly from an untrusted app. Sending a default-license PDF
to that integration would still disclose the paper to our server/provider,
even if the server deleted the bytes quickly. The source-only path therefore
does not enable Mathpix processing until one of these separately reviewed
routes exists:

- arXiv/copyright permission expressly covers contracted processing and the
  short-lived relay, with retention/deletion and provider terms recorded; or
- Mathpix offers an end-user credential/token model that keeps the request
  under the user's authorization and does not expose our service secret.

CC BY/CC0 papers and explicitly permitted publisher/user-uploaded PDFs may use
the existing server pipeline and shared conversion cache. The entitlement,
rights evidence, OCR operation and derived asset remain separate records so a
rights change can quarantine an artifact without deleting a user's metadata.

## Deletion and failure rules

- Removing a source-only import deletes the local PDF/bundle on that device
  after the local-store transaction commits; the cloud tombstone removes only
  metadata membership and encrypted references.
- A failed direct download remains source-only with a retry/open-source action;
  it is never converted into an owner-private server import automatically.
- Account deletion erases the account's local key and local paper blobs on
  each device when that device is next opened, and removes server metadata and
  encrypted chat according to the existing deletion protocol.
- Network loss leaves the local paper readable. A lost local key does not
  cause the server to reconstruct or re-download a source-only PDF silently.

## Rollout gates

Before enabling the device-local action in a release, complete:

1. local encrypted-paper store and blob integrity tests (the current store
   checkpoint covers the format; process-kill and disk-full cases remain);
2. source fetch, size/page limits, cancellation, process-kill and disk-full
   tests on iPhone, iPad and Mac Catalyst;
3. AirDrop package authentication and approved-device rotation tests;
4. reader-bundle installation from local storage, including MathML/figure
   validation and offline reopen; and
5. an explicit provider/rights decision for any Mathpix processing of
   source-only PDFs.

Until the remaining gates pass, the source-only state is intentionally honest:
metadata and the arXiv link are available everywhere, while the original PDF
is available only on a device that explicitly downloaded it. It is not yet a
multi-device server copy, a structured Mathpix reader, or an AirDrop transfer.
