# Third-party notices (app)

| Component | Use | License |
|---|---|---|
| [SwiftMath](https://github.com/mgriebling/SwiftMath) 1.7.3 | Native LaTeX math typesetting in chat answers | MIT (© 2023 Computer Inspirations) |
| Latin Modern Math (bundled by SwiftMath) | Math font for chat formulas | GUST Font License |
| [Mermaid](https://github.com/mermaid-js/mermaid) 12.1.0 browser build (`scripts/vendor-mermaid.mjs`, hash-pinned) | On-device drawing of diagrams from answers | MIT; bundled libraries keep their license comments in the file (DOMPurify Apache-2.0/MPL-2.0, d3 ISC, others MIT) |

| Math fonts bundled by SwiftMath (Latin Modern Math and others) | Chat formulas | GUST Font License; SIL Open Font License |
| [htmlparser2](https://github.com/fb55/htmlparser2), [Temml](https://temml.org) and what the reader scripts bundle (domhandler, domutils, dom-serializer, domelementtype, entities, @noble/hashes, fflate) | Preparing papers for reading on the device (`arxiv-reader.js`, `arxiv-source-metadata.js`, `device-pdf-reader.js`) | MIT; BSD-2-Clause |
| Google Sans (`GoogleSans-OFL.txt`) | The Google sign-in button | SIL Open Font License |

Reader bundles carry their own `NOTICE.txt` (renderer dependencies and per-paper attribution).
Settings → About → Acknowledgements lists these components, one row each, with each one's full notice text from
`apps/apple/ScienceReader/Resources/Licenses/` (Mermaid's and the reader scripts' written by `node scripts/app-notices.mjs`;
SwiftMath's and the math fonts' copied from the SwiftMath package). Run the script again after vendoring Mermaid or changing
the reader's dependencies.
