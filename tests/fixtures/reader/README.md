# Offline reading fixture

This is original authored sample content, not OCR output or a captured research article. It preserves the existing app sample title and section navigation while exercising repeated inline math, numbered attention, aligned equations, a matrix, a wide table, footnotes, and two separate figures.

Run `node tests/fixtures/reader/make-figures.mjs` from the repository root to reproduce the original PNG artwork. Run `node cli.mjs` from `workers/reader-renderer` to build a complete verified bundle. Its one-line JSON reports the output directory and trusted-review candidate manifest SHA. The application must explicitly adopt that SHA; discovering a directory does not authorize loading it.

Generated directories are content addressed and not overwritten. Earlier experimental directories are development artifacts, not alternative production profiles. The parent integration owns selection/copying of the reviewed final bundle into app resources. See the renderer README for the v1 contract, rejection behavior, local process bounds and remaining runtime/UI verification.

## Synthetic retained Mathpix outputs

`workers/reader-renderer/tests/mathpix-fixture.mjs` packages this same authored text and the two original PNGs under `paper/main.mmd` and `paper/assets/`. It also creates deliberately different standalone MMD, auxiliary line JSON and an explicitly synthetic document/attempt checkpoint. No PDF was verified or uploaded and no provider call occurred. This tests the retained-output adapter and reader contract, not Mathpix's real archive conventions or OCR accuracy.

From the repository root, run `node workers/reader-renderer/tests/mathpix-fixture.mjs .artifacts/mathpix-reader/raw`. Then pass the reported raw directory and its reviewed digest to `node workers/reader-renderer/cli.mjs --mathpix <raw-directory> <raw-manifest-sha256> .artifacts/mathpix-reader/readers`. The receiving adapter independently verifies the entire raw manifest and expanded inventory. Rendering consumes only the selected archived MMD and its referenced images; raw outputs stay outside the mobile bundle.

The reviewed local snapshot uses Node 24.18.0, renderer build `6c3abe61bf092e4346f38db8fe5f8c6c96af940212587885a86bb0761599e721`, raw manifest `de4d4f9cb5c2bc2c00db79e64d68238cd5bd59e60a32ccc9b2da10d6afab906c` and reader manifest `1423dcd31d00d694ecfbdbaaba7a6eeb0a123d0cf403ec4b22000e43d050c29e`. Its seven members total 149,220 bytes and retain seven equations and two figures. Only that verified reader directory is copied into `apps/apple/ScienceReader/Resources/ReaderSamples/`; the original authored `4851d817…` sample remains unchanged. Build identity includes runtime and production sources, so later renderer changes require review of a new digest, never substitution under an old one.

`OfflineReaderFixture` pins the new reader digest in Debug Simulator code. `--offline-reader-fixture --mathpix-reader-fixture --reset-offline-reader-fixture` installs it into a separate synthetic encrypted store. Relaunching with the first two arguments reopens only that installed copy; it does not reload the resource as a fallback. The UI explicitly labels the library row “Synthetic Mathpix.” This entry point is absent from device and release builds.
