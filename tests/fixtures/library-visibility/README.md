# Legacy library visibility capture

`legacy-v3.json` is frozen synthetic PostgreSQL output from
`tests/database/test_library_upload_visibility.sql`, after composing migrations
001–038, the pending039 ingress/descriptor snapshot, and
the visibility fragment (subsequently folded into039). It contains no customer
records, keys, PDFs or provider responses. `lineage.json` records the exact
fixture, SQL test, visibility fragment, ingress snapshot and capture-log hashes
at capture time. Later source changes do not silently regenerate this fixture.

The responses retain their SQL-produced values, including generated metadata
UUIDs, null fields and timestamps. No client-specific normalization or repair is
applied. Two mistakes in the initial synthetic SQL setup were fixed at the
source before capture: web/upload imports must have no requested revision, and
a public member in a full-wire mixed batch must retain its metadata payload.

The account's journal contains upload seq1, arXiv seq2, upload seq3, web seq4,
upload rename seq5, then a mixed removal group at seq6. Uploads include opaque
descriptor references. The legacy responses must omit those uploads and all
descriptor/source-level fields, including the source-null upload tombstone.

| Capture | SQL inputs / expected behavior |
|---|---|
| `baselines[0]` | Full level2, limit100: arXiv only; complete at5 |
| `baselines[1]` | Full level3, limit100: arXiv + web; complete at5 |
| `changes[0]` | After0, through5, limit1, level3: skip hidden prefix, emit seq2, continue at2 |
| `changes[1]` | After2, through5, limit1, level3: skip hidden middle, emit seq4, finish past hidden tail at5 |
| `changes[2]` | After0, through3, limit1, level3: emit seq2, finish past hidden tail at3 |
| `changes[3]` | After4, through5, limit1, level3: empty final page, finish at5 |
| `changes[4]` | After5, through6, limit1, level3: one atomic seq6 batch containing only its public member |

The unchanged Swift `LibraryWire.decodeBaseline` / `decodeChanges` decode every
captured page. A reconciler journey then applies the full baseline, final empty
catch-up and mixed removal. The unchanged web `Reconciler.pull` fetch/decode path
receives the pages through the existing RPC mock. Its zero-cursor bootstrap is
explicit test harness data so the earlier captured deltas can be exercised;
responses under test remain the captured SQL objects. Both suites also reject
the two shapes from the original pagination defect: an empty intermediate page,
and an intermediate cursor beyond its last emitted batch. No codec rule is
relaxed to make the fixtures pass.

Run focused checks from the repository root:

```sh
swift test --package-path apps/apple/ScienceReaderCore --filter LibraryVisibilityIntegrationTests
npm --prefix apps/web test -- --run tests/library-visibility.test.ts
```

To update the capture deliberately, first run the SQL visibility regression in
a fresh disposable local database using the reviewed ordered schema. Capture
unaligned `psql -X -qAt -v ON_ERROR_STOP=1` output and require that the SQL run
succeeds. It emits `LEGACY_DECODER_FIXTURE` and `LEGACY_MIXED_FIXTURE` markers.
Then use the exact composed039 snapshot applied by that run (the historical two-file capture also accepted
`--visibility-fragment`; omit it for the integrated migration):

```sh
python3 tests/fixtures/library-visibility/capture.py path/to/successful-sql-output.log \
  --ingress-snapshot path/to/039_ingress_snapshot.sql
```

The helper only reads local files and writes this fixture and its lineage; it
does not connect to a database or service. Review the diff and rerun both
unchanged decoder suites. This evidence does not activate v5 clients or establish
hosted upload behavior.
