# Direct metadata transport prototype

Status: development-only, loopback TLS fixtures only. No arXiv network route,
database credential, production grant, scheduler or deployment is implemented.
This is not a deployed beta backend. All hosted acquisition switches stay off.

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
attest that those parent/control-plane tasks ended. Integration should reuse the
reviewed TypeScript XML parser rather than introduce a second parser here.

The parent enforces one active child per local process, a total watchdog and
cancellation. That lock is not a cross-process or global gateway. It captures
bounded output, kills the child when needed, joins it, and reports its
observed exit separately. Malformed/missing child output cannot fabricate a body.
An ordinary timeout can therefore retire local ownership while retaining unknown
complete bytes. A parent crash has no surviving join witness in this prototype:
that case remains unresolved for future durable reconciliation. Source lifetime
is never inferred from a timer alone.

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

Pending migration 012 must bind an already-identified supervisor/child attempt,
authority epoch, source target and immutable runtime policy before any live I/O.
It must reserve executor and owned-connection holds atomically; a replay cannot
grant another request. Only an admitted parent witness can settle those holds.
Unknown/failed bodies retain the full transfer ceiling; a complete accepted body
may provide payload-byte accounting. Receipt-time cooldown is at least three
seconds, extended to any longer Retry-After delay. No such receipt is issued here.

A deployed gateway would need durable supervisor identity, bounded process
reconciliation and the same reviewed finite protocol. Running this on the
development Mac adds no hosting commitment but provides no always-on service or
hosted policy admission. No NAS, physical device, Storage or paid provider is
involved.

The next local-only boundary is proposed in [INTEGRATION.md](INTEGRATION.md).
It is not implemented by this fixture transport.

## Verification

Run `python3 -m unittest discover -s workers/source-gateway -p 'test_*.py'`.
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

Limits of this evidence: there was no public-network, DNS, grant, restart
reconciliation, deployment or sustained-load test. `HTTPResponse`'s narrow
private framing hooks were exercised on the interpreter above; a deployed Python
and TLS build must be pinned and revalidated. The prototype does not measure
encrypted wire bytes, peak process memory, remote application completion or
continuous-service availability. The joined child covers transport work only.
