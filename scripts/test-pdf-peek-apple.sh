#!/usr/bin/env bash
# Simulator only: the requested device and one companion of the other family on the same runtime.
# Both phone and tablet are required for this feature. Never enumerates or targets a physical device.
set -euo pipefail
if [[ $# != 1 ]]; then
  echo "Usage: bash scripts/test-pdf-peek-apple.sh SIMULATOR_UDID" >&2
  exit 2
fi
if ! command -v xcodebuild >/dev/null; then
  echo "Xcode is required; run this check on the Mac build host." >&2
  exit 2
fi
peek_simulator="$1"
peek_extra=()
if [[ -n "${PDF_PEEK_PDF:-}" ]]; then
  test -f "$PDF_PEEK_PDF"
  export TEST_RUNNER_PDF_PEEK_PDF="$PDF_PEEK_PDF"
  peek_extra+=(-only-testing:ScienceReaderTests/PDFPeekCorpusTests)
fi
peek_companion=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
requested = sys.argv[1]
for group in json.load(sys.stdin)["devices"].values():
    selected = next((d for d in group if d["udid"] == requested and d.get("isAvailable")), None)
    if selected:
        family = "iPad" if selected["name"].startswith("iPhone") else "iPhone"
        if not selected["name"].startswith(("iPhone", "iPad")):
            sys.exit("Use an iPhone or iPad Simulator.")
        companion = next((d for d in group if d.get("isAvailable") and d["name"].startswith(family)), None)
        if companion is None: sys.exit("An iPhone and iPad Simulator on the same runtime are required.")
        print(companion["udid"])
        break
else: sys.exit("The supplied identifier is not an available Simulator.")
' "$peek_simulator")
cd "$(dirname "$0")/../apps/apple"
xcodegen generate
peek_action=test
# Separate invocations avoid Xcode 26.4 stalling between serial destinations.
for peek_destination in "$peek_simulator" "$peek_companion"; do
xcodebuild -project ScienceReader.xcodeproj -scheme ScienceReader -configuration Debug \
  -destination "platform=iOS Simulator,id=$peek_destination" \
  -derivedDataPath ../../.artifacts/pdf-peek-derived \
  -only-testing:ScienceReaderTests/PDFPositionTests \
  -only-testing:ScienceReaderTests/PaperWebViewTests/testPDFSnapshotUsesLiveSelectionAndDoesNotMoveTheReader \
  -only-testing:ScienceReaderTests/PaperWebViewTests/testPDFSnapshotKeepsShortSelectionsAndEquationContextLocalInLongBlocks \
  -only-testing:ScienceReaderTests/PaperWebViewTests/testPDFSnapshotAtTwoFingerPointIgnoresOldSelectionWithoutClearingIt \
  -only-testing:ScienceReaderUITests/PDFPeekJourneyTests \
  -only-testing:ScienceReaderUITests/PaperToolsTests/testDoubleTapOpensContentsDeepInThePaperAfterAnEquationMenuAndAFling \
  "${peek_extra[@]}" \
  -parallel-testing-enabled NO \
  -enableCodeCoverage NO -collect-test-diagnostics never \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- "$peek_action"
peek_action=test-without-building
done
