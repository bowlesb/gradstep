#!/bin/sh
# Archive the Internal (staging) build and upload it to TestFlight (internal
# testing only) with the dedicated App Store Connect key in .env.appstore.
# Signing: the team's Apple Distribution certificate in the login keychain and
# the "Gradstep App Store" profile (the App Manager key cannot use cloud signing; it carries
# Sign in with Apple, In-App Purchase, Associated Domains and the App Group group.com.sciencereader.ios),
# and "Gradstep Share App Store" for the Share extension com.sciencereader.ios.share (App Group only).
set -eu
cd "$(dirname "$0")/.."
. ./.env.appstore
KEY="$(pwd)/$ASC_KEY_PATH"
BUILD="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
ARCHIVE=".artifacts/Paperstep-$BUILD.xcarchive"
AUTH="-authenticationKeyPath $KEY -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
(cd apps/apple && xcodebuild archive -project ScienceReader.xcodeproj -scheme ScienceReader -configuration Internal \
  -destination 'generic/platform=iOS' -archivePath "../../$ARCHIVE" -derivedDataPath ../../.artifacts/dd-archive \
  CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates $AUTH) > ".artifacts/archive-$BUILD.log" 2>&1
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
