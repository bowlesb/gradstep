import { canonical, sha256Hex, utf8 } from './util.ts';
import { THIRD_PARTY_NOTICES } from './notice.ts';

// Edge-compatible Mathpix renderer. Math is emitted as sanitized MathML for
// WebKit's native renderer (no SVG, no scripts, no fonts, no child process).
export const RENDERER_ID = 'timestep-mathpix-mathml-v1';
export const SOURCE_KIND = 'mathpix-mmd';
export const BUNDLE_FORMAT = 'reader-bundle-v1';
export const INDEX_FORMAT = 'reader-index-v1';
export const PROVENANCE_FORMAT = 'mathpix-reader-provenance-v2';
// Bump whenever rendering output can change for the same input bytes.
export const RENDERER_REVISION = 2;
export const PACKAGES = Object.freeze({ 'markdown-it': '9.1.0', 'mathpix-markdown-it': '3.0.1', htmlparser2: '12.0.0' });
export const MATH_OPTIONS = Object.freeze({
  include_latex: false, include_mathml: true, include_svg: false, include_asciimath: false,
  include_table_html: true, include_tsv: false, include_table_markdown: false, include_smiles: false,
  include_mathml_word: false,
});

// Limits are sized for real papers (the DPO capture is a 116 KB MMD with 270
// equations and four figures) while bounding hosted CPU/memory and native work.
export const LIMITS = Object.freeze({
  sourceBytes: 2 * 1024 * 1024,
  archiveImages: 512,
  figures: 256,
  imagesPerFigure: 16,
  equations: 4000,
  blocks: 20000,
  headings: 1000,
  textBytes: 20000,
  headingBytes: 2000,
  members: 512,
  bundleBytes: 32 * 1024 * 1024,
  memberBytes: 16 * 1024 * 1024,
  htmlBytes: 8 * 1024 * 1024,
  indexBytes: 4 * 1024 * 1024,
  manifestBytes: 256 * 1024,
  provenanceBytes: 256 * 1024,
  noticeBytes: 64 * 1024,
  imageDimension: 8192,
  imagePixels: 16_000_000,
  totalImagePixels: 64_000_000,
  domNodes: 400_000,
  domDepth: 160,
});

export const CSP = "default-src 'none'; img-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; base-uri 'none'; form-action 'none'; object-src 'none'; frame-src 'none'; connect-src 'none'";

// Generator-owned stylesheet. No url(), @import or @font-face: the bundle is
// self-contained. MathML inherits the root size, so Dynamic Type scales math.
export const READER_CSS = `:root{color-scheme:light dark;font:17px -apple-system,BlinkMacSystemFont,sans-serif;color:#222;background:#fff}
*{box-sizing:border-box}body{max-width:min(72ch,704px);margin:auto;padding:24px 22px 64px;line-height:1.6;overflow-wrap:break-word}
h1{font-size:1.6rem;line-height:1.22;letter-spacing:-.03em;margin:6px 0 14px}h2{font-size:1.25rem;line-height:1.3;letter-spacing:-.015em;margin-top:2em;scroll-margin-top:22px}h3,h4,h5,h6{font-size:1.05rem;margin-top:1.6em;scroll-margin-top:22px}
p{margin:1em 0}a{color:#5659d6;overflow-wrap:anywhere}strong,b{font-weight:650}::selection{background:#c7d2fe}
.reader-authors{font-size:.9rem;color:#555}.reader-abstract{font-size:.95rem}
math{font-family:"STIX Two Math",math;font-size:1.05em}
.reader-equation{direction:ltr;overflow-wrap:normal}.reader-inline{display:inline}
.reader-display{display:block;overflow-x:auto;overflow-y:hidden;max-width:100%;padding:12px 6px;margin:14px 0;text-align:center}
.reader-display>math{margin:0 auto}.reader-display.reader-tagged{display:flex;align-items:center;gap:1em}.reader-display.reader-tagged>math{flex:1 1 auto}
.reader-tag{flex:none;color:#555;font-size:.9em}.reader-math-fallback{font-family:ui-monospace,SFMono-Regular,monospace;font-size:.85em}
.reader-table{overflow-x:auto;max-width:100%;margin:24px 0;font-size:.85rem}.reader-table table{border-collapse:collapse}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #e5e7eb;vertical-align:top}th{font-weight:600}
.reader-caption,figcaption{font-size:.85rem;color:#555;margin-top:10px}
pre{overflow-x:auto;padding:14px;border:1px solid #e5e7eb;border-radius:8px;font-size:.8rem;line-height:1.45}code{font-family:ui-monospace,SFMono-Regular,monospace}
figure{margin:28px 0;cursor:pointer}figure img{display:block;max-width:100%;height:auto;margin:0 auto 6px;border-radius:6px}
ul,ol{padding-left:1.5em}li{margin:.45em 0}li.reader-custom-marker{list-style:none}.reader-marker{margin-right:.4em}
.reader-references li,.reader-footnotes li{font-size:.9rem}hr{border:0;border-top:1px solid #ddd;margin:2em 0}
@media(prefers-color-scheme:dark){:root{color:#ddd;background:#0f0f0f}a{color:#a5a7ff}.reader-authors,.reader-caption,figcaption,.reader-tag{color:#aaa}th,td,pre{border-color:#333}hr{border-color:#333}figure img{background:#fff}}
@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
`;

const BUILD_DESCRIPTOR = {
  domain: 'science-reader-renderer-build-v2', renderer: RENDERER_ID, revision: RENDERER_REVISION,
  packages: PACKAGES, math_options: MATH_OPTIONS, limits: LIMITS, csp: CSP,
};
// Content identity of the renderer configuration and its owned resources. It
// is not a hosted deployment attestation; REVISION covers code changes.
export const RENDERER_BUILD_SHA256 = sha256Hex(utf8(canonical({
  ...BUILD_DESCRIPTOR, css_sha256: sha256Hex(utf8(READER_CSS)), notice_sha256: sha256Hex(utf8(THIRD_PARTY_NOTICES)),
})));
