#!/bin/sh
# Archive the Internal (staging) build and upload it to TestFlight (internal
# testing only) with the dedicated App Store Connect key in .env.appstore.
# Signing: the team's Apple Distribution certificate in the login keychain and
# the "Gradstep App Store" profile (the App Manager key cannot use cloud signing; it carries
# Sign in with Apple, In-App Purchase, Associated Domains and the App Group group.com.sciencereader.ios),
# and "Gradstep Share App Store" for the Share extension com.sciencereader.ios.share (App Group only).
set -eu
cd "$(dirname "$0")/.."
node scripts/test-imports.mjs gate
. ./.env.appstore
KEY="$(pwd)/$ASC_KEY_PATH"
BUILD="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
# The on-device PDF route's models (docs/architecture/DEVICE_PDF_ROUTE.md): compiled into apps/apple/DeviceModels and
# checked against apps/apple/device-models.lock.json; a build without them hides the experiment, so say so loudly.
# Since 2026-10-24 they are a separate download ("The models as a download"): the folder is the On-Demand Resources tag
# `device-pdf-models`, which the archive and the upload below carry as an asset pack beside the app (App Store hosted),
# and the script also writes apps/apple/DeviceModelsManifest/device-models-pack.json, which the app ships.
node scripts/device-models.mjs --require-encryption > ".artifacts/device-models-$BUILD.log" 2>&1 || { echo "Device models not prepared: .artifacts/device-models-$BUILD.log"; exit 1; }
# The native loader is built and team-signed separately; a CLI success on an unsigned/old pack is insufficient.
: "${SCIENCE_READER_COREML_VERIFY_TOOL:?set the path to the team-signed DevicePDFRouteTool}"
SCIENCE_READER_COREML_VERIFICATION="$(pwd)/.artifacts/coreml-encryption-$BUILD.json"
export SCIENCE_READER_COREML_VERIFICATION
node scripts/verify-coreml-encryption.mjs --tool "$SCIENCE_READER_COREML_VERIFY_TOOL" \
  --models apps/apple/DeviceModels --manifest apps/apple/DeviceModelsManifest/device-models-pack.json \
  --out "$SCIENCE_READER_COREML_VERIFICATION"
(cd apps/apple && xcodegen generate > /dev/null)
ARCHIVE=".artifacts/Paperstep-$BUILD.xcarchive"
AUTH="-authenticationKeyPath $KEY -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
(cd apps/apple && xcodebuild archive -project ScienceReader.xcodeproj -scheme ScienceReader -configuration Internal \
  -destination 'generic/platform=iOS' -archivePath "../../$ARCHIVE" -derivedDataPath ../../.artifacts/dd-archive \
  CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates $AUTH) > ".artifacts/archive-$BUILD.log" 2>&1
# Refuse an upload if import code changed while the archive was being built.
node scripts/test-imports.mjs gate
node scripts/check-ios-model-boundary.mjs "$ARCHIVE/Products/Applications/ScienceReader.app"
node scripts/check-device-model-pack.mjs "$ARCHIVE"
cat > .artifacts/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string><key>destination</key><string>upload</string>
  <key>teamID</key><string>3BJ33TT599</string><key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict><key>com.sciencereader.ios</key><string>Gradstep App Store</string>
    <key>com.sciencereader.ios.share</key><string>Gradstep Share App Store</string></dict>
  <key>uploadSymbols</key><true/><key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><true/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist .artifacts/ExportOptions.plist \
  -exportPath ".artifacts/Paperstep-$BUILD-export" $AUTH > ".artifacts/export-$BUILD.log" 2>&1
grep -E "Upload succeeded|EXPORT SUCCEEDED" ".artifacts/export-$BUILD.log"
echo "Uploaded build $BUILD"
