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
# Errors inside dependency checkouts are noise when the app's own code is at fault, but when they
# are the only errors they are the diagnosis: show them rather than nothing.
errors=$(grep -E "error:" "$log" | grep -v "/checkouts/" || true)
if [[ -n "$errors" ]]; then
  print -r -- "$errors"
elif ! grep -q "BUILD SUCCEEDED" "$log"; then
  grep -E "error:" "$log" || tail -n 40 "$log"
fi
grep -E "BUILD (SUCCEEDED|FAILED)" "$log" || true
grep -q "BUILD SUCCEEDED" "$log" || { echo "Build failed. Full log: $log" >&2; exit 1; }
rm -f "$log"

# Re-sign with the local signing identity when it exists, so macOS keeps microphone, Keychain
# and Automation permissions across rebuilds (an ad-hoc signature changes with every build).
# Create the identity once with Scripts/make-signing-identity.sh. A signing failure fails the
# build: the stable signature is what the permissions depend on, so "built" must not be reported
# when it was not applied.
identity=$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/"Lectern Local Signing"/ { split($0, a, " "); print a[2]; exit }')
if [[ -n "$identity" ]]; then
  sign_log=$(mktemp)
  if ! codesign --force --deep --preserve-metadata=entitlements --sign "$identity" "$APP" >"$sign_log" 2>&1; then
    grep -v "replacing existing signature" "$sign_log" >&2 || true
    rm -f "$sign_log"
    echo "Signing with Lectern Local Signing FAILED; $APP is not signed with it." >&2
    exit 1
  fi
  rm -f "$sign_log"
  if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
    echo "Signing with Lectern Local Signing did not produce a valid signature for $APP." >&2
    exit 1
  fi
  echo "Signed with Lectern Local Signing"
else
  echo "Ad-hoc signed (run Scripts/make-signing-identity.sh to keep permissions across rebuilds)"
fi
echo "App: $APP"
