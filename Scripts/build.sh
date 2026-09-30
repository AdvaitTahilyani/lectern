#!/bin/zsh
# Builds Lectern.app. Usage: Scripts/build.sh [derived-data-name] [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
DD="build/${1:-DD-main}"
CONFIG="${2:-Debug}"
APP="$DD/Build/Products/$CONFIG/Lectern.app"
xcodegen generate --quiet >/dev/null  # picks up added/removed source files
log=$(mktemp)
xcodebuild -project Lectern.xcodeproj -scheme Lectern -configuration "$CONFIG" \
  -derivedDataPath "$DD" -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation build >"$log" 2>&1 || true
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$log" | grep -v "/checkouts/" || true
grep -q "BUILD SUCCEEDED" "$log" || { rm -f "$log"; exit 1; }
rm -f "$log"

# Re-sign with the local signing identity when it exists, so macOS keeps microphone, Keychain
# and Automation permissions across rebuilds (an ad-hoc signature changes with every build).
# Create the identity once with Scripts/make-signing-identity.sh.
identity=$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/"Lectern Local Signing"/ { split($0, a, " "); print a[2]; exit }')
if [[ -n "$identity" ]]; then
  codesign --force --deep --preserve-metadata=entitlements --sign "$identity" "$APP" 2>&1 | grep -v "replacing existing signature" || true
  echo "Signed with Lectern Local Signing"
else
  echo "Ad-hoc signed (run Scripts/make-signing-identity.sh to keep permissions across rebuilds)"
fi
echo "App: $APP"
