#!/bin/zsh
# Runs the app-hosted unit tests (App/LecternAppTests). Usage: Scripts/test-app.sh [derived-data-name]
set -euo pipefail
cd "$(dirname "$0")/.."
DD="build/${1:-DD-main}"
xcodegen generate --quiet >/dev/null  # picks up added/removed source files
log=$(mktemp)
xcodebuild test -project Lectern.xcodeproj -scheme Lectern -configuration Debug \
  -derivedDataPath "$DD" -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation >"$log" 2>&1 || true
grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)" "$log" | grep -vE "/checkouts/|\[Connection\]" || true
grep -q "TEST SUCCEEDED" "$log" || { echo "Full log: $log"; exit 1; }
rm -f "$log"
