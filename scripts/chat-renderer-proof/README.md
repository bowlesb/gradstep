# Local chat formatting component proofs

These experiments check authored TeX typesetting, exact source parsing/copying,
and their combined validated DOM output with existing pinned dependencies. They do not render customer
messages, ship app resources, change schemas, contact providers, or use a
physical phone. The source grammar is a limited Markdown profile, and the
components are not a complete chat renderer. See
[native chat rendering](../../docs/architecture/NATIVE_CHAT_RENDERING.md) for
the adoption requirements and remaining work.

From the repository root, with the existing root and reader-renderer dependencies:

```sh
node scripts/chat-renderer-proof/build.mjs
node scripts/chat-renderer-proof/browser.mjs
xcrun swiftc -swift-version 6 -parse-as-library scripts/chat-renderer-proof/webkit.swift -o .artifacts/chat-typesetter-component/webkit-proof
.artifacts/chat-typesetter-component/webkit-proof .artifacts/chat-typesetter-component
```

For the source-only component:

```sh
node --test scripts/chat-renderer-proof/tokenizer.test.mjs
node scripts/chat-renderer-proof/build-source.mjs
node scripts/chat-renderer-proof/browser.mjs source
xcrun swiftc -swift-version 6 -parse-as-library scripts/chat-renderer-proof/webkit.swift -o .artifacts/chat-source-component/webkit-proof
.artifacts/chat-source-component/webkit-proof .artifacts/chat-source-component source
```

The source build has its own closed dependency graph and licenses. It imports no
typesetter or separate HTML parser. It tests raw/body spans, distinct repeated equations,
whole-message/equation copying, code exclusions, Unicode, comments, nesting,
currency and limits. Two invalid-surrogate fixtures use explicit code-unit
arrays for transport through Foundation; the JS adapter reconstructs them
immediately before admission. No real message uses this test representation.

The source grammar is deliberately limited: other Markdown stays literal;
CR/NUL, unsupported syntax and ambiguous math request an exact-source fallback.
Digit-led prices and trailing literal dollars remain prose. The result is an
in-memory experiment, not a persistence or cross-device contract. These checks
do not establish native visual selection, rendered copying or row layout.

For the combined completed-message proof:

```sh
node --test scripts/chat-renderer-proof/output-policy.test.mjs
node scripts/chat-renderer-proof/build-message.mjs
node scripts/chat-renderer-proof/browser.mjs message
xcrun swiftc -swift-version 6 -parse-as-library scripts/chat-renderer-proof/webkit.swift -o .artifacts/chat-message-component/webkit-proof
.artifacts/chat-message-component/webkit-proof .artifacts/chat-message-component message
```

This adds 33 authored browser/WebKit cases and 46 output-policy checks. One
message uses one fresh realm and aggregate typesetter/validated-output budgets.
Compiled MathML rejects author resource/style attributes, including base
`mmlToken` routes. Strict namespace-aware SAX parsing rejects unsupported
generated SVG/MathML; only checked AST nodes enter `createElementNS`. Prose is
inserted as original text. No `innerHTML`, source HTML parser or remote resources
are used. All equations validate before the detached message DOM is built.
A failure publishes only the entire original source, with no partial equations.

The proof resolves actual DOM ranges to original text/equation sidecars,
including ranges inside SVG or assistive MathML, repeated equations, mixed
ranges and scalar-safe Unicode boundaries. It keeps whole-message copying
distinct from mixed selection (which substitutes exact equation LaTeX without
inline delimiters). It does not intercept the system clipboard or establish
iOS gesture/VoiceOver behavior. Generated presentation IDs are namespaced and
their growth is metered; owned wrappers/prose/style nodes count too. Each
equation has one hidden-from-accessibility visual SVG and one assistive MathML
tree. Structural uniqueness does not prove accessibility usability.

Owned fixture CSS retains the pinned MathJax table overflow rules. At 320px,
the authored attention equation reaches the end of its horizontal scroll area
without widening the message. Initial/scrolled-end, align, matrix/cases, mixed
text and failure screenshots are saved for inspection. This is not acceptance
of the native transcript layout, scroll affordance, font scaling or row reuse.

The closed message graph adds saxes 6.0.0 and xmlchars 2.2.0. Its nine packages,
notices, exact source/harness hashes and both lockfiles are recorded in
`build.json`. The installed saxes package omits its license file, so the exact
[tagged upstream license](https://raw.githubusercontent.com/lddubeau/saxes/v6.0.0/LICENSE)
is retained in `licenses/saxes-6.0.0-LICENSE`; the build itself is offline.
The source-only notice census also includes its root-level `entities` package.

Run sequentially and stop on failure. The browser check requires the existing
Playwright Chromium installation; the native check requires macOS and Xcode.
The build refuses Node/external/disabled imports and unexpected packages. It
retains its dependency graph, input hashes and MathJax license alongside the
bundle. Generated files live only in the ignored artifact directory.

The browser and native harnesses use the same packaged fixture definitions and
record their hash. Each case has a fresh realm; reusing a consumed realm is
refused. Native checks use an in-memory scheme, a nonpersistent store, disabled
page JavaScript, an isolated content world and an invocation-bound reply bridge.
Only the message mode constructs validated generated DOM; its CSP allows the
fixed owned stylesheet and validated SVG layout declarations. Other modes have
no generated DOM. Only fixed identifiers, counters and
status enums enter reports; source, macro/label text and exception messages are
excluded. The packaged fixtures and local screenshots contain only authored public examples.

The factory/adaptor counters stop the known expansion before SVG generation.
They bound selected allocations and output estimates, not every parser operation,
peak memory or execution time. The 55-second native watchdog aborts this test;
it is not a WebContent termination mechanism. Do not use this harness on private
or arbitrary input or treat a pass as authorization to enable rich chat.

The prior `equation`/`align` failures were verifier bugs: the old traversal asked
`LiteAdaptor.childNodes` to inspect label text nodes. These fixtures now require
successful conversion and text-node traversal. Unknown implementation errors
are reported separately from TeX errors so they cannot hide as unsupported math.
