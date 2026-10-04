# Local chat typesetter component proof

This experiment runs authored TeX fixtures through the existing pinned
MathJax dependency. It does not render customer messages, ship app resources,
change schemas, contact providers, or use a physical phone. It is not a Markdown
parser or a complete chat renderer. See
[native chat rendering](../../docs/architecture/NATIVE_CHAT_RENDERING.md) for
the adoption requirements and remaining work.

From the repository root, with the existing root and reader-renderer dependencies:

```sh
node scripts/chat-renderer-proof/build.mjs
node scripts/chat-renderer-proof/browser.mjs
xcrun swiftc -swift-version 6 -parse-as-library scripts/chat-renderer-proof/webkit.swift -o .artifacts/chat-typesetter-component/webkit-proof
.artifacts/chat-typesetter-component/webkit-proof .artifacts/chat-typesetter-component
```

Run sequentially and stop on failure. The browser check requires the existing
Playwright Chromium installation; the native check requires macOS and Xcode.
The build refuses Node/external/disabled imports and unexpected packages. It
retains its dependency graph, input hashes and MathJax license alongside the
bundle. Generated files live only in the ignored artifact directory.

The browser and native harnesses use the same packaged fixture definitions and
record their hash. Each case has a fresh realm; reusing a consumed realm is
refused. Native checks use an in-memory scheme, a nonpersistent store, disabled
page JavaScript, an isolated content world and an invocation-bound reply bridge.
The page never receives generated markup. Only fixed identifiers, counters and
status enums enter reports; source, macro/label text and exception messages are
excluded. The packaged fixtures themselves contain only authored public examples.

The factory/adaptor counters stop the known expansion before SVG generation.
They bound selected allocations and output estimates, not every parser operation,
peak memory or execution time. The 55-second native watchdog aborts this test;
it is not a WebContent termination mechanism. Do not use this harness on private
or arbitrary input or treat a pass as authorization to enable rich chat.

The prior `equation`/`align` failures were verifier bugs: the old traversal asked
`LiteAdaptor.childNodes` to inspect label text nodes. These fixtures now require
successful conversion and text-node traversal. Unknown implementation errors
are reported separately from TeX errors so they cannot hide as unsupported math.
