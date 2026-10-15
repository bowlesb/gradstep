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
. ./.env.appstore
KEY="$(pwd)/$ASC_KEY_PATH"
BUILD="${BUILD_NUMBER:?set BUILD_NUMBER (it must be higher than every earlier upload, iOS or Mac)}"
PROFILE_NAME="Gradstep Mac App Store"
ARCHIVE=".artifacts/Gradstep-mac-$BUILD.xcarchive"
AUTH="-authenticationKeyPath $KEY -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
mkdir -p .artifacts
# The on-device PDF route's models (docs/architecture/DEVICE_PDF_ROUTE.md), as in upload-testflight.sh. An iOS upload
# of the same build has just prepared them; checking again is cheap when they match the lock.
[ -f apps/apple/DeviceModels/device-models.json ] || node scripts/device-models.mjs > ".artifacts/device-models-mac-$BUILD.log" 2>&1 || { echo "Device models not prepared"; exit 1; }
(cd apps/apple && xcodegen generate > /dev/null)
(cd apps/apple && xcodebuild archive -project ScienceReader.xcodeproj -scheme ScienceReader -configuration Internal \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' -archivePath "../../$ARCHIVE" \
  -derivedDataPath ../../.artifacts/dd-archive-mac CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates $AUTH) \
  > ".artifacts/archive-mac-$BUILD.log" 2>&1
echo "Archived $ARCHIVE"

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
