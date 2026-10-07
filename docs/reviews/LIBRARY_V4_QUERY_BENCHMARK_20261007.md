# Library v4 query benchmark review — 2026-10-07

Independent implementation review and local benchmark. This is a backend read-model experiment, not a capacity rollout.

Final source: migration 032 SHA-256 `1d185795d503052e7a91ca91bc998f85088507af532cc1465e1d82f3c5074e41`.
The source hash matched the working file after the final run.

Reproduce with `python3 scripts/benchmark-library-query.py`. The script creates and
drops its own `science_reader_test_*_query_bench` database at `127.0.0.1:55431`,
strips inherited libpq environment options, refuses other endpoint/name patterns,
and snapshots migration source hashes. `--compare-variants` additionally measures
isolated private-function overrides in that disposable database and restores them.
No policy values, hosted databases, migration source files, or product limits change.

## Final evidence

Raw artifacts are retained under `.artifacts/library-v4-20261007/` in the integration worktree; the script regenerates them.

- `query-benchmark-20261007T215209Z.json`: full measurements, source hashes, fixtures,
  storage, index sizes, plans and cleanup status.
- `query-benchmark-20261007T215209Z.md`: all case summaries.
- `query-benchmark-20261007T215209Z-plans.txt`: original nested `auto_explain` output.
- Earlier baseline: `query-benchmark-20261007T214201Z.*`.
- Controlled comparison: `query-benchmark-20261007T214651Z.*`.

The final run recorded **92 cases, three samples each**, with no budget or ordering
failures. All disposable databases were dropped. Preregistered limits were under
5,000 ms per server query and command, and at most 1,048,576 response bytes.
The largest observed server query was **405.158 ms**, command **433.679 ms**, and
page **114,871 bytes**. These are warm local observations, not production targets.

The fixture contains 5,000 metadata records totaling 24,022,751 encoded bytes;
500 records are exactly 32,768 bytes and every record passes the real metadata
validator. Account retained-entry counts are 20, 50, 51, 10,000 and 50,000. The
50/51 accounts have exactly that many visible, active rows. The larger accounts
include 5% hidden and 10% archived rows, leaving 42,500 active rows in the 50k account.
Metadata identities repeat across entries, so this is not a 50k unique-paper test.

Canonical full-title ordering, without the production 64-character prefix, matches
every first/second/deep sort page and both directions of prefix-collision pages.
A separate inspection of retained results verified all three samples for four
known all-matching searches at all five account sizes against their recent-order
reference IDs (20 case checks). The script now performs these checks directly.

## Changes justified by the plans

| Case | Earlier plan | Final plan |
|---|---|---|
| 50k recent, after 25,000 results | 25,000 rows removed before 51 returned | Direct typed tuple index condition; 51 visited, none removed; 405 buffer hits |
| 50k title ASC, after 25,000 results | 25,061 rows and metadata lookups; 100,704 hits | Coarse prefix index seek plus exact full-title comparison; 71 rows, 494 hits |
| 20-entry, 16 common terms | 16 global metadata candidate scans; approximately 74k hits | Account-joined metadata; 274 hits; median 6.598 ms |

No-term list plans perform no small-library count query. The bounded count chooses
the joined path at 50 visible entries and the GIN path at 51. Both return the expected
IDs. This is a conservative, measurable strategy boundary: the deliberately broad
16-term query measured median 9.105 ms / 967 hits at 50 versus 167.476 ms / 74,410 hits
at 51. The remaining global work is explicit.

An always-joined experiment helped tiny accounts but hurt large ones: the 50k
16-term case increased from approximately 234 ms to 1,324 ms median and spilled
1,375 temporary blocks. It is not a justified unconditional replacement.

## Storage and limits of the evidence

Physical table + index totals after all 60,121 retained rows were populated:

| Relation | Table / TOAST bytes | Index bytes | Total bytes |
|---|---:|---:|---:|
| Canonical metadata | 26,386,432 | 1,097,728 | 27,484,160 |
| Shared query metadata | 30,007,296 | 31,973,376 | 61,980,672 |
| Compact current entries | 78,225,408 | 13,393,920 | 91,619,328 |
| Account query entries | 21,454,848 | 39,419,904 | 60,874,752 |

These are fresh synthetic table sizes, not per-account allocations or a storage
forecast. The account `own_search` GIN occupied 8,175,616 bytes and had zero scans
in this workload; that is a future index-cost review item, not proof it can never help.

PostgreSQL was local 18.4 on Apple Silicon, with 128 MB shared buffers and 4 MB
`work_mem`. Other developer/Xcode work was running. Samples include RPC execution
and JSON byte counting, exclude HTTP/client rendering, and do not establish cold
cache, concurrent-user, battery, or production latency. Title DESC/year access,
large identical-prefix groups, short no-match terms, and larger catalogs still need
capacity-specific review. No larger account allowance or client rollout is warranted
by this benchmark alone.
