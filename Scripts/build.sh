#!/bin/zsh
# Builds Lectern.app. Usage: Scripts/build.sh [derived-data-name] [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
DD="build/${1:-DD-main}"
CONFIG="${2:-Debug}"
[[ -d Lectern.xcodeproj ]] || xcodegen generate >/dev/null
xcodebuild -project Lectern.xcodeproj -scheme Lectern -configuration "$CONFIG" \
  -derivedDataPath "$DD" -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | grep -v "/checkouts/" || true
echo "App: $DD/Build/Products/$CONFIG/Lectern.app"
