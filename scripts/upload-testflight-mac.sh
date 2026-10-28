#!/bin/sh
# Archive the Mac app (Mac Catalyst, Internal = staging configuration) and upload it to TestFlight for
# Mac (internal testing only) on the same App Store record and bundle ID as iOS. See
# docs/architecture/MAC_APP.md. Usage: BUILD_NUMBER=15 scripts/upload-testflight-mac.sh
#
# Signing (the App Manager key cannot use cloud signing, so both are local):
# - the app: the team's Apple Distribution certificate (the same one iOS uses) and a Mac Catalyst
#   App Store profile named "Gradstep Mac App Store" (Sign in with Apple, In-App Purchase, Associated
#   Domains), installed in ~/Library/Developer/Xcode/UserData/Provisioning Profiles;
# - the installer package: a "3rd Party Mac Developer Installer" (Mac Installer Distribution) identity
#   in the login keychain.
# Without them the script still archives (proving the build signs), then stops and says what is missing.
set -eu
cd "$(dirname "$0")/.."
node scripts/test-imports.mjs gate
BUILD="${BUILD_NUMBER:?set BUILD_NUMBER (it must be higher than every earlier upload, iOS or Mac)}"
PROFILE_NAME="Gradstep Mac App Store"
ARCHIVE=".artifacts/Gradstep-mac-$BUILD.xcarchive"
mkdir -p .artifacts
# The on-device PDF route's models (docs/architecture/DEVICE_PDF_ROUTE.md), as in upload-testflight.sh. Rebuild and
# qualify the exact encrypted pack for this archive. The Mac app keeps the
# models inside the app (On-Demand Resources don't exist on the Mac; ENABLE_ON_DEMAND_RESOURCES is off for Mac Catalyst).
# Reship (JUDGMENT_LOG 56), as in upload-testflight.sh: RESHIP_DEVICE_PACK=<64-hex version> copies a recorded shipped
# pack unchanged (apps/apple/device-models-shipped.json) and skips encryption; any other pack must be encrypted and
# pass the signed verification. PREPARE_ONLY=1 stops after this model gate, before the archive and the App Store key.
if [ -n "${RESHIP_DEVICE_PACK:-}" ]; then
  unset SCIENCE_READER_COREML_VERIFICATION
  node scripts/device-models.mjs --reship-pack "$RESHIP_DEVICE_PACK" ${RESHIP_DEVICE_PACK_FROM:+--reship-from "$RESHIP_DEVICE_PACK_FROM"} \
    > ".artifacts/device-models-mac-$BUILD.log" 2>&1 || { echo "Recorded device model pack not prepared: .artifacts/device-models-mac-$BUILD.log"; exit 1; }
  PACK_MODE="--reship-pack $RESHIP_DEVICE_PACK"
else
  node scripts/device-models.mjs --require-encryption > ".artifacts/device-models-mac-$BUILD.log" 2>&1 || { echo "Encrypted device models not prepared"; exit 1; }
  # The native loader is built and team-signed separately; a CLI success on an unsigned/old pack is insufficient.
  : "${SCIENCE_READER_COREML_VERIFY_TOOL:?set the path to the team-signed DevicePDFRouteTool}"
  SCIENCE_READER_COREML_VERIFICATION="$(pwd)/.artifacts/coreml-encryption-$BUILD.json"
  export SCIENCE_READER_COREML_VERIFICATION
  node scripts/verify-coreml-encryption.mjs --tool "$SCIENCE_READER_COREML_VERIFY_TOOL" \
    --models apps/apple/DeviceModels --manifest apps/apple/DeviceModelsManifest/device-models-pack.json \
    --out "$SCIENCE_READER_COREML_VERIFICATION"
  PACK_MODE=""
fi
cat ".artifacts/device-models-mac-$BUILD.log"
if [ "${PREPARE_ONLY:-}" = 1 ]; then echo "Prepared device models for Mac build $BUILD; stopping before the archive (PREPARE_ONLY=1)"; exit 0; fi
. ./.env.appstore
KEY="$(pwd)/$ASC_KEY_PATH"
AUTH="-authenticationKeyPath $KEY -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
(cd apps/apple && xcodegen generate > /dev/null)
(cd apps/apple && xcodebuild archive -project ScienceReader.xcodeproj -scheme ScienceReader -configuration Internal \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' -archivePath "../../$ARCHIVE" \
  -derivedDataPath ../../.artifacts/dd-archive-mac CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates $AUTH) \
  > ".artifacts/archive-mac-$BUILD.log" 2>&1
echo "Archived $ARCHIVE"
node scripts/test-imports.mjs gate
node scripts/check-device-model-pack.mjs --mac $PACK_MODE "$ARCHIVE"

missing=""
security find-identity -v | grep -q "3rd Party Mac Developer Installer" ||
  missing="$missing\n- a \"3rd Party Mac Developer Installer\" identity (certificate and private key) in the login keychain"
grep -rlq "<string>$PROFILE_NAME</string>" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" 2>/dev/null ||
  missing="$missing\n- the Mac Catalyst App Store profile \"$PROFILE_NAME\" for com.sciencereader.ios"
if [ -n "$missing" ]; then
  printf "Not uploaded. Needed first:%b\n" "$missing"
  exit 2
fi

cat > .artifacts/ExportOptions-mac.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string><key>destination</key><string>upload</string>
  <key>teamID</key><string>3BJ33TT599</string><key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>
  <key>provisioningProfiles</key><dict><key>com.sciencereader.ios</key><string>$PROFILE_NAME</string></dict>
  <key>uploadSymbols</key><true/><key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><true/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist .artifacts/ExportOptions-mac.plist \
  -exportPath ".artifacts/Gradstep-mac-$BUILD-export" $AUTH > ".artifacts/export-mac-$BUILD.log" 2>&1
grep -E "Upload succeeded|EXPORT SUCCEEDED" ".artifacts/export-mac-$BUILD.log"
echo "Uploaded Mac build $BUILD"
