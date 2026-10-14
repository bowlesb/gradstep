# Device-local papers and reader bundles

Status: owner direction expanded 2026-10-13 to **every PDF**, regardless of source/license. The native encrypted
arXiv source-only PDF store/viewer checkpoint was implemented locally on 2026-10-09. Universal local intake,
arXiv HTML preparation, local bundle installation and server-side PDF prohibition are implemented and deployed on staging; native build 29 passed Apple processing and is in internal testing. Browser PDF bytes remain in the device file/tab; choosing the file again after reopening is explicit.
The authoritative new contract is [HTML-first reader](HTML_FIRST_READER.md).

## Content boundary

PDFs are downloaded, opened, stored and processed only on the user's device. This includes licensed arXiv papers,
publisher PDFs and files supplied by choosing, dropping or sharing them into the app. No device download is
followed by a server upload. No credential/token arrangement for Mathpix creates an exception to this decision.
Initially, only official arXiv HTML is adapted to the structured reader. A future local model handles difficult
PDFs; until it passes quality/device/license checks, the original remains locally viewable without cloud OCR.

The default HTML path is also direct device acquisition and local adaptation. Server hosting of HTML or its
derivatives still requires exact-version rights evidence and a separately reviewed implementation. The existing
rights fields describe permission, not whether a PDF may be processed in the cloud. `rights_mode=shared` must not
be used to exempt a PDF from the device-only rule.

## What synchronizes

The service may retain normalized source identity and exact revision, bibliographic metadata, license evidence,
versioned source URLs, library membership/tags/removal state and the existing encrypted private-event streams.
It does not receive PDFs or a background upload of their extracted text, images or derived bundles in the new flow.
Local readiness, PDF hashes and installed bundle inventory stay on the device. Reading activity retains its
existing device-local policy; this change does not add reading-position synchronization.

Explicit cloud paper chat remains a separate request: necessary bounded text/TeX and selected passages may be
sent in request memory under the existing AI consent and server spending gates. That is not a plaintext sync or
storage path. See [local-context chat](HTML_FIRST_READER.md#paper-chat-and-other-derived-work).

## Device flow

1. Add resolves metadata and an exact source revision. Membership must work without a server PDF/document row;
   the new capability-versioned identity contract must be implemented before that is claimed to work.
2. Fetch the official HTML for that revision and bounded assets, adapt them to the new `arxiv-html` bundle profile,
   validate independently, then atomically install the encrypted bundle. Existing Contents, figures, selection,
   equation Copy, references and paper chat remain the interface. Missing or unsupported HTML produces a clear
   local/source availability state and never triggers remote PDF processing.
3. Download an original directly to the device through the bounded HTTPS/PDF validator, or accept a local file
   through choose/drop/Share. Encrypt it into the local paper store without passing through `PDFUploadQueue`.
   Original and prepared-bundle availability are independent; neither requires the other to succeed.
4. Bind each local object to the account and source/version (or an account-scoped random local-file identity), its
   byte digest and the local-store key. A later arXiv revision is a new record and does not replace reading anchors.
5. Another approved device synchronizes membership and encrypted private data, then retrieves the pinned source
   itself or imports an authenticated approved-device package once transfer is implemented. Do not present another
   device's local PDF as available here. Key recovery does not recreate a missing file.

Browser direct acquisition needs a separate CORS proof; opening an arXiv tab does not prove that the browser app
can read and bundle the response. No server PDF proxy is an acceptable workaround.

## Existing native checkpoint and required extension

`DevicePaperStore` is a migration-free, file-backed store beside encrypted metadata. Keeping large PDF ciphertext
out of the SQLite journal avoids inflating sync checkpoints and WAL files. The checkpoint has an authenticated
manifest, atomic writes, orphan pruning, bounds, blob integrity and account retirement fences. Its current native
entry is **only** source-only arXiv retrieval and local PDF viewing. The failed-publisher download and chosen-file
flows elsewhere still enter the upload queue; they must be rerouted before claiming all PDFs are local.

Extend this store contract for arbitrary PDF identities and verified HTML bundles, retaining explicit open,
delete, capacity, integrity and retirement operations. Keep protected transient plaintext lifetimes bounded and
remove incomplete temporary files after cancellation/restart. Exclude local paper content from automatic
OS/cloud backups, and verify browser eviction and native disk-full behavior. Reuse `ReaderBundleCoordinator`
installation and the existing offline stores after removing their requirement for a server-original identity;
never install fake document/approval references.

## Approved-device transfer (designed, not implemented)

AirDrop/device transfer carries a bounded encrypted package with source identity, exact revision, the original
if present and any verified bundle. Authenticate the sender and bind the package to the intended approved
recipient/account, wrapping its content key with the device-key protocol. Verify signature, revision, all member
hashes and limits before atomic installation. Include no reusable service token, provider credential or plaintext
chat. Present this as transfer between the user's approved devices, not public sharing or account reassignment.

## Deletion and failures

- Local removal deletes that device's original/bundle without pretending that cloud membership or another device's
  files were erased. Removing library membership follows the normal tombstone/accepted-write rules and cleans up
  associated local content without letting stale downloads reinstall it.
- Account deletion/retirement invalidates pending work and clears local keys/blobs on each device when next opened.
- Interrupted/failed acquisition retains any previously verified bundle and offers a bounded retry/source action;
  it never falls back to an owner-private server import or remote OCR.
- Offline reading uses complete verified local members with no network dependency. Browser storage eviction or a
  lost original is reported honestly; recovery codes recover keys, not the absent paper bytes.

## Verification gates

Use the [coordinated cutover sequence](HTML_FIRST_READER.md#cutover-and-verification-sequence): HTML/asset and
hostile-input adapter fixtures; native/Core/browser verifier agreement; encrypted install/offline reopen;
source-version anchors and chat parity; all intake/retry routes; process-kill/disk-full/account fencing; browser
CORS/quotas; and server traces proving no PDF acquisition/upload/processing or Mathpix calls, including old clients.
Approved-device transfer and the future PDF model have their own authentication/quality gates. Physical iPhone
work remains paused; Simulator and Catalyst verification may continue.

No existing hosted files were migrated or deleted by this design change. The old deployed PDF/Mathpix paths and
historical retained copies require the explicit cutover/retention work in the authoritative design; do not claim
that the deployed app already implements this device-only contract.
