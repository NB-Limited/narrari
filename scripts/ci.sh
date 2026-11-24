#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/check.sh
bash scripts/check-rules.sh

identity=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
if [ -z "$identity" ]; then
  echo "No valid Apple Development certificate in the keychain." >&2
  echo "Create one in Xcode: Settings > Accounts > Manage Certificates > + > Apple Development." >&2
  exit 1
fi
# Expired certificates share the name, so the team is read from the one valid identity.
team=$(security find-certificate -a -c "Apple Development" -Z -p \
  | awk -v hash="$identity" '/^SHA-1 hash:/ {keep = ($3 == hash)} keep' \
  | openssl x509 -noout -subject -nameopt multiline \
  | awk -F'= ' '/organizationalUnitName/ {print $2; exit}')

swift build
swift test

xcodegen generate --quiet
# Xcode keeps an embedded resource bundle from an earlier build when only the files inside it changed, so the app is assembled anew.
rm -rf build/Build/Products/Release/Narrari.app
xcodebuild -project Narrari.xcodeproj -scheme Narrari -configuration Release \
  -derivedDataPath build -quiet COMPILER_INDEX_STORE_ENABLE=YES \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$team" build

periphery scan --quiet
