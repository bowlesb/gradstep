# Native chat formatting

Status, 2026-10-04: **Direct typesetter component passes browser and macOS WebKit
checks. No rich-chat renderer is integrated.** The native transcript displays saved source
through SwiftUI text in a self-sizing `UITableView`. Its completed-turn scrolling,
keyboard, selection and encrypted-restart journeys already have regression
evidence. Saved equation questions still expose raw LaTeX. This document plans
that formatting gap without changing storage, navigation or cloud processing.

## First proof and decision boundary

Use the existing synthetic reader workflow: select the attention equation, save
the question, reopen encrypted history, then read and copy the formatted question.
Begin with completed prose and display equations, including complete `equation`
environments. Inline and repeated equations are correctness fixtures. Markdown
headings/lists/code/tables and mutable streaming follow after the first proof;
provider consent, transport and credit settlement remain separate work.

First establish a standalone browser package from the already pinned local
renderer dependencies. It must tokenize, admit and typeset within a closed local
dependency graph. The current reader adapter uses Node filesystem/crypto modules
and one fresh subprocess per document; it cannot be shipped directly into iOS.
No stubbed Node facilities, remote loader or fallback CDN may conceal a missing
browser dependency. Retain the exact dependency graph, build inputs, notices,
sizes and unresolved requirements before choosing app integration.

The first local graph probe is retained under
`.artifacts/chat-browser-proof-20261004-25ae5fdf/`. It used the existing Node
24.18.0 and esbuild 0.28.2 installations and made no app, WebKit, network or
provider change. The full Mathpix entry and the independent sanitizer were
rejected because their reachable graphs import Node `fs`, `path`, `url` and
`events`, PostCSS, and `opentype.js` font-loading code. A Mathpix typesetter
entry did bundle at 3,675,153 bytes, but this is only a graph result and does
not establish parser compatibility or safe pre-admission. Separate markdown
tokenizer and direct MathJax bundles built at 331,226 and 2,371,968 bytes.

The browser execution probe ran in a local Chromium 153.0.8010.12 page with
network requests, console calls and page errors counted. Inline fractions and
small macros rendered, and a fresh realm rejected a macro defined in the prior
realm. The initial report incorrectly classified the attention `equation` and
`align` fixtures as TeX failures. A subsequent audit using the identical bundle
(`a73e4804…a8ea88`) found a verifier bug: `LiteAdaptor.childNodes` requires an
element, but the traversal called it on equation-label text nodes. Conversion
succeeded; inspection then threw a `TypeError`, which the probe incorrectly
reported as `tex_error`. The original reports are preserved as superseded
evidence, not engine incompatibility. A short macro expansion produced
13,313,390 bytes before the
post-generation 1 MiB output rejection; MathJax `maxBuffer` limits parser
concatenation rather than cumulative SVG allocation. This is negative evidence:
source/output limits and `maxBuffer` do not establish a WebContent heap or CPU
bound.

The token probe confirms that the four intended TeX token kinds skip conversion
under `forLatex:true`, but the plugin's inline MathML rule calls
`TypesetMathML` during parsing before a post-parse allowlist can reject it. The
probe intercepted that call; it did not render hostile input. Any future
candidate must tokenize/admit with an explicitly safe profile before calling a
typesetter, or maintain a reviewed parser fork. It cannot claim that the broad
Mathpix plugin is safe merely because unsupported tokens are rejected later.

The graph and browser artifacts have no production authority. The next proof
must establish a compatible bounded tokenizer, exact source sidecars and output
validation before any Swift chat row or shipping renderer package is added.

A successful browser build is insufficient. The component now executes in an
actual macOS `WKContentWorld` with page JavaScript disabled, local resources only
and a native bridge, as recorded below. This does not establish iOS layout or
view ownership. Preserve the regular transcript until the candidate meets the
native adoption checks below.

### Reproducible component proof

The checked-in harness is `scripts/chat-renderer-proof/`; generated bundle,
dependency graph, notices and results are in
`.artifacts/chat-typesetter-component/`. It uses the existing pinned MathJax
3.2.2 dependency, with only base, AMS and newcommand TeX packages, SVG fonts
bundled as paths, no autoload/require/HTML packages and an empty base URL.
The graph has no external, disabled or Node imports. Nothing from this directory
is part of an app target or hosted worker.

Both Chromium 153.0.8010.12 and macOS 26.3.1 WebKit pass the same 18 authored
fixtures. The complete attention equation, numbered align, unnumbered equation,
inline fraction and matrix succeed. Labels exercise text-node traversal;
verification failures are separate from TeX failures. Fresh realms reject a
previous realm's macro; a consumed realm refuses another invocation. Resource
commands, an expansion loop, oversized source and deliberately lowered factory,
text, SVG-node and serialization-estimate limits are covered.

The native harness uses a fresh named content world and nonpersistent store per
fixture. Page JavaScript is disabled, and a page-script marker stays absent even
though the fixture's CSP permits that inline script. The page world cannot see
the typesetter global. A main-frame, invocation-bound message/reply bridge
accepts only a small metrics result. All 18 cases report one owned in-memory
document load, no additional resource entries, no rejected navigation/request,
no CSP violation and no console/error calls. No generated HTML or source is
returned through the message/reply bridge or inserted into the page DOM. These are component execution checks, not
selection, accessibility, display or network-process telemetry.

The previous 13.3 MB expansion now stops during compilation after 2,000 MML
node creations, with only the 12 fixed lite-document nodes and no SVG generation.
Counts include creator-map calls, text updates, clone operations, style/class
changes and escaped serialization estimates. Source HTML never enters the lite
parser. The compiled tree is checked before the same MathItem proceeds to SVG;
it is not compiled a second time. Limits are cumulative, without refunds.

This improves early refusal but **does not establish a hard heap or CPU bound**:
`maxMacros` is per parser; parser strings, constructor arguments, recursive
compilation and other intermediates are not fully metered. The estimate does
not bound peak serialization allocation. The fixed fixtures do not establish
safe execution of arbitrary customer input. Timeout aborts the harness and
never opens a replacement slot; it does not prove WebContent termination.

Independent source review recommends app-owned math rules with a narrowly
enabled markdown-it profile. Importing selected `mdPluginRaw` exports still
imports its broad conversion graph. Stock normalization and paragraph trimming
need explicit source-span handling; code fences, escaped delimiters, comments,
nested environments, blank lines and repeated formulas are required fixtures.
The tokenizer, source sidecars, independent output sanitizer, aggregate message
budget, retirement lifecycle and iOS presentation remain unimplemented.

## Mathematical identity and admission

The paper renderer uses `mathpix-markdown-it` 3.0.1, `markdown-it` 9.1.0,
`mathjax-full` 3.2.2, `sanitize-html` 2.18.0 and `htmlparser2` 12.0.0, pinned by its
lockfile. Reuse the reviewed semantics where browser packaging permits it. The
candidate must establish that `forLatex:true` defers conversion for every admitted
math token before relying on a tokenize/admit/typeset sequence.

Every equation's exact LaTeX, display mode and source form come from the same
parser token that is typeset. Delimited body tokens and complete environment
tokens remain distinct. Repeated formulas have distinct identities. Never match
equations by rendered order or a native regular expression. The ephemeral result
has its own chat contract; private messages are not fabricated authored-paper
bundles or shared article artifacts.

Provisional proof ceilings are 32 KiB source, 64 blocks, 16 math tokens, 12 KiB
per equation and 1 MiB output, plus finite DOM depth/node and equation geometry
limits. These are experiment bounds, not a new persisted-message limit. Identify
and test actual TeX buffer and macro-expansion controls before running hostile
input. Reject unsupported source HTML, images, styles, fonts and resource loads
before they can acquire authority; final HTML sanitization alone is too late to
prevent parser-triggered fetching. Links are inert in the first proof.

Reuse the independent SVG/MathML/fragment validation and source-controlled
attribute rejection where feasible. A result is complete or unavailable, never
silently stripped while its sidecar claims lost content. Failure preserves the
complete selectable stored source with a concise formatting-unavailable state.
Raw source and upstream error text never enter logs or retained diagnostics.

## Ownership, privacy and failure

The proposed prototype has a process-wide maximum of three chat WebViews: one
serialized typesetter and two reusable display surfaces. Attached, idle,
executing and retiring instances all count. Display surfaces receive sanitized,
already-typeset content and never rerun TeX. This is an experimental bound, not
a production capacity policy: ordinary dense transcripts may need more than two
simultaneous rich rows, and selected/focused surfaces cannot be recycled away.
Three WebViews do not establish three independent WebContent processes or an
aggregate memory/CPU bound. Pending requests also need finite retained-byte and
count limits before they can enter the serialized typesetter. For the proof,
admit at most two pending sources and 64 KiB aggregate pending UTF-8 bytes before
retaining them. The per-source cap remains 32 KiB and the per-equation cap 12 KiB.
Two one-row display surfaces cannot satisfy the three-visible-rich-row adoption
gate below. Packaging success therefore requires a separate measured capacity
and layout decision before production integration.

Each typesetting request needs a fresh document/module realm. The existing
Mathpix reset clears tags but does not clear all user TeX macros. A timeout,
`stopLoading`, navigation or dropping a Swift reference does not prove hard CPU
termination. Unresolved execution quarantines its slot and prevents repeated
invocations or replacement allocation until a valid retirement condition exists.
A release must belong to the exact invocation: its terminal result after all
owned rendering work has completed, or observed termination of its WebContent
process. A stale callback, elapsed deadline or new navigation is insufficient.
Prove this lifecycle before treating time limits as resource containment.

Derived output stays in account/session-partitioned memory. The initial cache
proposal is at most 8 MiB and 16 entries, accounting for all retained source,
sidecar and rendered bytes. Cache eviction does not delete encrypted history.
Use nonpersistent WebKit stores and exact local resources; reject network and
unexpected scheme/navigation loads. This introduces no plaintext disk cache,
server-rendered transcript, schema or encryption-format change. Sign-out and
conversation replacement retire leases and reject all late results.

## Layout, selection and accessibility

Keep the current table as the only vertical scroll owner, with the existing
bubble spacing, role/status presentation, composer, Latest action and stable
message anchors. Scope render and height callbacks to account session, composer,
message identity, source/render revision, actual content width, font, theme,
surface lease and load identity. A width change must not accept a stale height.

Measure initial content before publishing a formatted row. Coalesce later
pixel-quantized height changes through the existing table coordinator. Capture
the current visible anchor immediately before applying each change; an anchor
captured when rendering began may no longer express the user's position. Do not
introduce nested vertical scrolling or a second imperative scroll owner.

Whole-message Copy returns the exact stored source. Mixed prose/equation
selection resolves ordered validated parts, without duplicating hidden LaTeX or
MathML and without treating an SVG as empty text. Preserve ordinary prose
selection and complete environment syntax. Assistive MathML is present once,
with the author label separate. Real WebKit selection and VoiceOver behavior
must be checked; valid markup alone establishes neither.

## Required evidence before adoption

- Exact source and equation equivalence after encrypted restart, including
  labels, repeated formulas, escaped currency and code-like delimiters.
- Fresh-message macro isolation, pre-typeset resource denial and hostile
  HTML/TeX/link refusal, without private console/error output.
- Actual isolated-world execution with page JavaScript disabled and no network
  requests; exact dependency/asset ownership and notices.
- Initial and delayed height changes during following, deliberate scrollback,
  keyboard growth/dismissal, Dynamic Type and iPad resizing.
- Held callbacks across cell reuse, source replacement, conversation switching,
  renderer failure and account retirement.
- Native Copy preserving draft/context and exact mixed mathematical content;
  meaningful accessibility checks, including selected/focused row retention.
- Dense-history traversal that respects the surface/cache bounds without normal
  scrolling causing formatting failures, flicker, blank rows or repeated work,
  including at least three simultaneously visible rich messages while another
  row owns selection or accessibility focus.
- Acceptable latency and both app and WebContent memory across repeated message
  and conversation changes. Simulator results do not establish physical-device
  resource acceptance; physical iPhone work remains paused.

Failure of the browser or view-ownership proof requires a reviewed alternative,
not a silent expansion of the view pool or a whole-transcript replacement.
Native TextKit/math attachments remain an alternative requiring separate TeX
compatibility, selection, layout and accessibility evidence.
