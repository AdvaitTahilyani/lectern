#!/bin/zsh
# Runs every LecternKit package test suite through xcodebuild. (`swift test` can't compile MLX's
# Metal shaders when the installed Metal toolchain is newer than Xcode's shim expects; xcodebuild
# resolves the toolchain itself.) Usage: Scripts/test-package.sh [derived-data-name]
set -euo pipefail
cd "$(dirname "$0")/../Packages/LecternKit"
DD="../../build/${1:-DD-package}"
log=$(mktemp)
xcodebuild test -scheme LecternKit-Package -destination 'platform=macOS' -derivedDataPath "$DD" \
  -skipPackagePluginValidation -skipMacroValidation >"$log" 2>&1 || true
grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)" "$log" | grep -vE "/checkouts/|\[Connection\]" || true
grep -q "TEST SUCCEEDED" "$log" || { echo "Full log: $log"; exit 1; }
rm -f "$log"
