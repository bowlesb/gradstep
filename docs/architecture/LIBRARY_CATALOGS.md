# Named library catalogs

Designed October 19 before implementation. Native and browser implementation is under verification; not yet released. Owner request: Library's top-right menu contains **Catalogs**;
rename the existing catalog, create, switch, choose a default, and delete with a choice to delete its papers or
move them to an existing/new named catalog. Keep the current Library arrangement, paper identities and chats.

## Behavior

Every paper belongs to one catalog. Existing/unassigned papers appear in **Default**, which can be renamed.
The configured default chooses the initial catalog; a new import joins the catalog selected when Add was pressed.
Changing the default never moves existing papers. Library counts, filters, search and pending rows are scoped to
the selected catalog. Opening a paper, Feed ownership, general chat and existing conversations keep their current
identities. Switching catalogs clears a tag filter that would otherwise obscure the newly selected collection.

The Catalogs sheet lists each name and paper count with an active checkmark. Selecting a row switches immediately.
Create asks for a name. Each row offers Rename, Make default and Delete. At least one catalog remains. A small
current-catalog switcher in Library makes repeated switching accessible without rearranging its rows or columns.

Delete first requires an explicit disposition: **Move papers** to an existing catalog, **Move to new catalog**
with its name, or **Delete papers** with destructive confirmation and the affected count. Moving changes only
catalog association. Deleting papers uses the existing library removal/cancel/local-PDF tombstone paths; it must
not merely hide them by deleting their catalog. Retained chats follow the existing paper-removal policy.

## Private state and compatibility

Catalog names, defaults and assignments live in the existing encrypted private-event journal; no hosted schema,
plaintext preference or server access grant is added. Device-only PDF rules remain unchanged. The published
`PrivateEvent.Kind` set cannot gain a new required case: older clients would reject that event and stop syncing.
Use a bounded, versioned JSON payload in an existing `.note` event on a reserved catalog-metadata entity, without
a conversation or document binding. Older clients can retain/decrypt that valid note and ignore its catalog
meaning; neither app currently renders an unbound note as a message. Do not create fake conversation records.

Each payload contains a bounded batch of catalog operations and uses the metadata entity's observed heads as
parents. Operations create/rename a catalog, select the default, assign a stable paper key, or retire a catalog
with a destination. Reduce by causal height and an immutable batch UUID inside the encrypted payload as the
concurrent tie-breaker, never device time, arrival order or replaceable envelope IDs. Missing ancestors defer
dependent operations. Unknown future payloads still supply ancestry but apply no operations, without
invalidating other encrypted history. Key-rotation replacement event identities use the existing PrivateState
replacement mechanism. Names are trimmed, nonempty and bounded; IDs, not names, establish identity.

An arXiv paper key derives from its normalized source identifier, so queued import → source membership → installed
paper keeps its catalog. Local and legacy document keys use their stable UUID. Pending imports without a resolved
document retain their source key. Re-adding a previously removed paper explicitly assigns it to the currently
selected catalog. An older client that adds without catalog metadata places that paper in the original Default.

Retiring a catalog records a durable redirect for its assignments, including concurrent assignments to that
catalog. Follow redirect chains with cycle protection and deterministic fallback to the original Default.
Concurrent edits cannot make papers disappear. Deleting the current/default catalog selects the named destination;
deleting the final catalog's papers creates an empty replacement. Default/catalog identities never grant account
access and are retired from memory on account changes.

## Removal and persistence

Persist assignment before beginning an import; a catalog association without an actual library paper is harmless,
whereas a network import must not silently lose its intended catalog. Persist related local-PDF membership and
assignment in one private-event batch where possible. All writes use the current account's store/session guards.

A destructive catalog removal captures the papers the reader confirmed and their actual revision preconditions.
Keep the catalog visible while its removals are pending; wait for normal confirmed library catch-up, and do not
replace uncertain operation IDs or rebase conflicting revisions. If a removal fails, show progress and keep the
remaining catalog/papers available for review. The native client retains its ordinary durable commands across a crash/relaunch. The browser uses its existing
session-memory command/receipt queue: after reopening, it loads the current server state and the reader can
confirm the remaining papers; a whole catalog-deletion batch is not automatically resumed. Papers
added concurrently after confirmation are not authorized for deletion: leave the catalog available until the
reader explicitly resolves them. Do not claim atomic server removal of multiple papers.

## Verification

Core checks cover initial/default semantics, rename, causal/concurrent ordering, missing-parent arrival, key
replacement, redirects/cycles, assignments made concurrently with deletion and malformed/future payloads. Native
and browser journeys cover create/rename/switch/default/relaunch, adding into a selected catalog, and each deletion
disposition. Failure/cancellation preserves undeleted papers and their catalog. Verify account isolation and old
event decoder compatibility. Run the required import gate for the changed ReaderModel/Library views before upload.
No provider calls are required for this feature or its verification.


## Implementation checkpoint — October 19 UTC

The native and browser implementations share the encrypted note schema and causal reduction. Seven Core and
seven browser unit cases cover projection and key replacement. The native model/PDF checks pass 11 cases,
including actual encrypted-store reopening, import assignment, the same durable removal request after failure,
and keeping a paper added after confirmation. One real-PDF corpus case is opt-in and is covered separately by
the mandatory import gate. Screen journeys and final import acceptance remain pending at this checkpoint.

The deletion regression exposed a saved membership and pending source intent sharing one paper key. Removal
must plan both physical records, skipping the second only if a grouped server transition already hid it. Logical
paper-key deduplication is appropriate for counts, not for deleting the underlying records. The fixture's cancel
handler now supports its baseline imports too. Its encrypted event stub accepts numeric JSON receipts.

No hosted schema, server PDF processing or paid model call is added. Names and associations use the existing
account-bound encrypted journal; library removal keeps its existing data-retention policy.
