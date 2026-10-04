# Direct metadata transport prototype

Status: development-only transport and local metadata integration. The harness
uses disposable PostgreSQL databases and loopback TLS fixtures only. It has no
arXiv network route, provisioned role credential, production grant, scheduler or
deployment. This is not a deployed beta backend. Hosted acquisition stays off.

The prototype separates HTTP message completion, TLS peer-close evidence and
retirement of the socket-owning process. Neither a response nor a child-written
`closed` field establishes process retirement. The parent must join the exact
child it launched; it never claims arbitrary remote application work stopped.

## Fixed contract

- Input is a normalized arXiv source ID, optional integer revision, `atom` or
  `license` stage, and a body ceiling no greater than 1 MiB. Derive only the
  existing canonical `export.arxiv.org/api/query` or `oaipmh.arxiv.org/oai`
  route. Caller URLs, headers, credentials and alternate source hosts are absent.
- Source networking is disabled. The fixture adapter connects to one explicitly
  supplied IPv4 loopback address/port and verifies the canonical source hostname
  against a fixture CA. It performs no DNS lookup. A future admitted resolver
  must select one address per grant; automatic address fallback is not allowed.
- One child owns one socket and all HTTP file wrappers. It creates no descendants
  and receives no database or service credentials. No proxy, pooling, redirect,
  retry, compression negotiation or automatic decompression is used. Send HTTP/1.1
  with `Connection: close` and `Accept-Encoding: identity`.
- Use Python's `HTTPResponse` parser with bounded I/O and stricter finite header
  policy. Refuse ambiguous length/transfer encodings, unsupported encodings,
  informational/upgrade responses, malformed lines and excess protocol data.
  Do not implement a general HTTP stack.
- Limits: 1 MiB body; 2 MiB received TLS-plaintext protocol bytes; 16 KiB initial
  headers, 64 fields and 8 KiB per line; 1 KiB chunk/trailer lines and 64 KiB of
  those lines; 30 seconds useful I/O, 250 ms optional peer-close observation,
  plus one parent-enforced 1-second supervision allowance, split into 500 ms
  startup/reporting and 500 ms stop/drain/join. There is no second grace window;
  slow startup can be cut off before the child's relative timeout. Tests may only
  shorten these deadlines. IPC input is at most 24 KiB; output at most 1.5 MiB;
  retained child stderr at most 4 KiB.
  These byte counts are not encrypted wire-traffic or TLS-overhead measurements.
- Set `suppress_ragged_eofs=False`. Complete Content-Length/chunk framing can
  establish a complete response after abrupt TLS EOF; a close-delimited response
  needs clean TLS closure. HTTP parser EOF and TLS EOF are distinct. Clean TLS
  EOF does not assert the TCP peer closed. No socket is reused after TLS shutdown.
  [RFC 9112 section 9.8](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.8),
  [Python TLS API](https://docs.python.org/3/library/ssl.html).

## Failure and retirement

The child emits a bounded finite result: response status, framing mode/completion,
TLS-close observation, payload bytes/hash only for a complete accepted message,
received protocol-byte count and an enumerated failure. It explicitly closes the
HTTP response/file wrapper and TLS/socket references in all paths. Output is
diagnostic data, never a database receipt or permission to fetch again.

The owned executor scope is transport only: TLS setup, one HTTP request, bounded
message framing, hashing and reference cleanup. XML parsing, catalog decisions
and database result handling are outside this child. Its joined exit cannot
attest that those parent/control-plane tasks ended. Integration reuses a captured
standalone build of the reviewed TypeScript XML parser.

The parent enforces one active child per local process, a total watchdog and
cancellation. That lock is not a cross-process or global gateway. It captures
bounded output, kills the child when needed, joins it, and reports its
observed exit separately. Malformed/missing child output cannot fabricate a body.
An ordinary timeout can therefore retire local ownership while retaining unknown
complete bytes. A parent crash before a durable join checkpoint has no surviving
join witness and remains unresolved. Source lifetime is never inferred from a
timer alone.

Stop/drain ends at its fixed deadline even if a kill or pipe EOF is unconfirmed.
The parent then emits `unresolved`, discards any previously received body and
keeps the exact `Popen` handle with the local lane locked. `reconcile_fixture()`
can only retry bounded stop/join of that retained child; a new invocation remains
blocked until the exact exit is observed. This in-memory handle does not survive
parent failure and is not a durable recovery mechanism or observer receipt.

Before launch, the parent captures and hashes the exact child modules. The
stdlib-only child runs with `-I -S -B`, an empty credential/proxy environment,
closed inherited descriptors and a dedicated session. Its only added import path
is the captured recipe. No child-spawning code or descriptor export is present.
This is an ownership property of this reviewed prototype, not an OS sandbox for
arbitrary Python code. Host/runtime admission is still required before use with
source authority.

Pending migration 012 binds an already-identified supervisor/child attempt,
authority epoch, source target and immutable runtime policy before any live I/O.
It must reserve executor and owned-connection holds atomically; a replay cannot
grant another request. Only an admitted parent witness can settle those holds.
Unknown/failed bodies retain the full transfer ceiling; a complete accepted body
may provide payload-byte accounting. Receipt-time cooldown is at least three
seconds, extended to any longer Retry-After delay. The integration issues these
receipts only inside its disposable local database.

A deployed gateway would need durable supervisor identity, bounded process
reconciliation and the same reviewed finite protocol. Running this on the
development Mac adds no hosting commitment but provides no always-on service or
hosted policy admission. No NAS, physical device, Storage or paid provider is
involved.

The reviewed contract and its remaining deployment boundaries are in
[INTEGRATION.md](INTEGRATION.md).

## Local database integration

`frozen.capture(parent, parser_bundle)` captures the complete controller/child
module graph, exact bootstrap, standalone `parser.mjs` and parser manifest before
execution. Scope hashes derive from that manifest. Python and Deno executable
digests are recorded and rechecked before launch; Python/TLS/Deno versions are
retained. The local host, operating-system libraries and filesystem ownership
remain assumptions, not an admitted immutable OS image. The parser builder is
`scripts/build-metadata-parser.py`; it uses already-installed pinned local tools.
The exact bundled JavaScript must also receive loader/import source review:
static build-graph checks cannot establish the absence of every dynamic loader.

The frozen coordinator launches an identified paused child, persists its intent,
and invokes one grant RPC. macOS boot/start identity comes from `sysctl`/`libproc`;
Linux uses boot ID and `/proc` start ticks; an unsupported platform refuses. Only
the exact committed grant can send GO, after comparing its source/stage/version
to the child's captured request and accounting for RPC time using a monotonic
deadline. The cross-process clock is explicit `clock_gettime(CLOCK_MONOTONIC)` on
macOS and `clock_gettime(CLOCK_BOOTTIME)` on Linux, including system sleep;
Python 3.9 on macOS gives `time.monotonic()` a process-local origin and cannot
supply this deadline. A SELECT row preceding failed or missing COMMIT acknowledgement grants
no I/O. Cancellation is checked again after the GO checkpoint and before the
first control write.

The private journal bounds each action to 32 files, 4 MiB total and 1.5 MiB per
file. Its complete worst-case envelope is checked before grant. It stores the
body once, then rehydrates parser input from that witness. File fsync, atomic
no-overwrite publication and directory fsync precede dependent mutations;
reopening establishes fresh file/directory durability barriers. A later join of
the same retained handle is saved separately from an earlier unresolved witness.
Receipt acknowledgements must match the exact execution and canonical resource
facts. A bounded recovery invocation replays saved receipts/result arguments,
including license `observed_at`; it never grants, launches or refetches.
Canonical JSON uses compact UTF-8, matching catalog/parser byte limits for
non-ASCII abstracts and pinned metadata; SQL's binding digest stays opaque.

The local `psql` adapter permits only unique `science_reader_gateway_<12hex>`
databases at `127.0.0.1:55431`. Tests initialize actual migrations 001–012 with UTC
database timezone and drop only their own databases. They start as the local
database owner and use `SET LOCAL ROLE` for the allowlisted executor/observer RPCs.
This tests role capability surfaces; it is **not** provisioned credential
separation. The synthetic host/project identity and test policy never admit this
developer machine for production. Fixture setup alone uses the admitter role.

The parser runs with Deno config/npm/remote resolution disabled, all application
permissions denied, bounded input/output, and a five-second subprocess watchdog.
These Deno permissions are not an OS sandbox. XML/result handling is separate
from the socket-owning child's executor receipt. Complete-body accounting counts
payload bytes only. Unsupported or over-limit Retry-After—including HTTP dates
whose clock safety is unproved—retains the **database** connection hold; local
process retirement does not silently shorten the source delay.

## Verification

Run `python3 -m unittest discover -s workers/source-gateway -p 'test_*.py' -v`.
Tests generate a temporary loopback-only TLS certificate and exercise actual
child processes and sockets. They must cover complete/truncated framing,
clean/abrupt TLS EOF, slow handshake/body, retained file references, size/header
limits, redirected/compressed responses, watchdog cancellation and kill/join.
No test may contact an arXiv hostname. Independent source review is complete for
this loopback-only prototype, including its bounded unresolved-child handling.

Local execution: **23 tests passed in 7.878 seconds**, Python 3.9.6 / LibreSSL
2.8.3 on arm64. The suite also checks a full 1 MiB body, independent chunk-line
overhead, late TLS/cleanup failures, caller mutation after launch and a crashed
parent producing no retirement witness. Two close-error regressions inject faults
around actual loopback TLS. One restricted fake-process test keeps valid output
and pipe handles while refusing retirement; it verifies bounded drain, discarded
body, blocked successors and retained-handle reconciliation, including caller
mutation of the returned unresolved diagnostic. Other transport
cases use unmodified subprocess code. Temporary fixture certificates and keys
are deleted by the test harness.

The unchanged 23-test prototype also passed in **4.214 seconds** on the project's
existing local Python 3.13.3 / OpenSSL 3.5.0 (8 Apr 2025), arm64. Root ran this
compatibility check; its evidence is `.artifacts/source-gateway-python313.log`.
That verifies these framing and lifecycle regressions on a second local runtime;
it is not a deployment, host-security or source-network admission.

The integrated suite additionally exercises real SELECT/COMMIT failure, lost
receipt/result replies, an original uncommitted grant becoming visible later,
source-stage change and cancellation before GO, real Atom→license parsing,
bounded status/error accounting, full one-MiB checkpoint capacity, exact-witness
reopening, and parent death leaving database holds. Boundary fault injections
live only in the test harness, outside the captured recipe.

Completed integration checkpoint: **54 tests passed on both local runtimes**
(23 transport, 8 coordination, 23 PostgreSQL/TLS integration cases):

- Python 3.9.6 / LibreSSL 2.8.3: 69.083 seconds;
  `.artifacts/source-gateway-integration-final.log`.
- Python 3.13.3 / OpenSSL 3.5.0: 61.437 seconds;
  `.artifacts/source-gateway-integration-python313.log`.
- `.artifacts/source-gateway-integration-evidence.json` records both captured
  manifests, log hashes and unchanged hashes for all 12 migration files. Its
  SHA-256 is `c0f85719c64d2e4e4bbd73a4155c90484ee42b3cea04cb89a59a2f638def2c7f`.
- Both runs used standalone parser SHA-256
  `668d65700b17b5024f8cfbf13f5db4a55954b718b470ac9a8b402aff4781ba25`
  (86,359 bytes). Captured coordinator bundle identities differ by Python runtime
  and are retained in that evidence file. No fixture databases remain.

Limits of this evidence: there was no public-network, DNS, hosted grant,
unwitnessed-process restart recovery, deployment or sustained-load test.
`HTTPResponse`'s narrow
private framing hooks were exercised on the interpreter above; a deployed Python
and TLS build must be pinned and revalidated. The prototype does not measure
encrypted wire bytes, peak process memory, remote application completion or
continuous-service availability. The selected clock's documented sleep behavior
is not an executed suspend/resume or restored-host experiment. Linux execution
and every deployed host still require validation and admission. The joined child
covers transport work only.
