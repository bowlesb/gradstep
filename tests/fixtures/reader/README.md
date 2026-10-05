# Offline reading fixture

This is original authored sample content, not OCR output or a captured research article. It preserves the existing app sample title and section navigation while exercising repeated inline math, numbered attention, aligned equations, a matrix, a wide table, footnotes, and two separate figures.

Run `node tests/fixtures/reader/make-figures.mjs` from the repository root to reproduce the original PNG artwork. Run `node cli.mjs` from `workers/reader-renderer` to build a complete verified bundle. Its one-line JSON reports the output directory and trusted-review candidate manifest SHA. The application must explicitly adopt that SHA; discovering a directory does not authorize loading it.

Generated directories are content addressed and not overwritten. Earlier experimental directories are development artifacts, not alternative production profiles. The parent integration owns selection/copying of the reviewed final bundle into app resources. See the renderer README for the v1 contract, rejection behavior, local process bounds and remaining runtime/UI verification.

## Mathpix reader fixture

The earlier synthetic retained-Mathpix fixture (`1423dcd3…`) was removed with the `timestep-mathpix-mmd-v1` pilot. The app's Mathpix fixture is now `apps/apple/ScienceReader/Resources/ReaderSamples/d874c0ed…`, rendered by `scripts/render-mathpix-reader.ts` from the retained real capture of arXiv 2305.18290 (CC BY 4.0) with the attribution in `tests/fixtures/reader-mathpix/dpo-attribution.txt`. `OfflineReaderFixture` pins that digest in Debug Simulator code; `--offline-reader-fixture --mathpix-reader-fixture --reset-offline-reader-fixture` installs it into a separate synthetic encrypted store. See [Reader renderer](../../../docs/architecture/READER_RENDERER.md).
