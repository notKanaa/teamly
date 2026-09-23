#!/usr/bin/env bash
# Builds an unsigned Release .ipa (to be re-signed on the user's side with Sideloadly + a free Apple ID).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
set -o pipefail
mkdir -p ci-logs
xcodebuild build \
  -project TeamTasks.xcodeproj -scheme TeamTasks -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/dd -clonedSourcePackagesDirPath .spm \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  2>&1 | tee ci-logs/xcodebuild-ipa.log | xcbeautify
APP="build/dd/Build/Products/Release-iphoneos/TeamTasks.app"
test -d "$APP"
rm -rf build/ipa build/Equipe-unsigned.ipa
mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
(cd build/ipa && zip -qry ../Equipe-unsigned.ipa Payload)
ls -la build/Equipe-unsigned.ipa
