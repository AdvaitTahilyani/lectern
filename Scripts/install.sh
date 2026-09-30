#!/bin/zsh
# Builds a Release Lectern.app and installs it to /Applications (replacing an existing copy).
# Usage: Scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build.sh DD-release Release
app="build/DD-release/Build/Products/Release/Lectern.app"
[[ -d "$app" ]] || { echo "Build did not produce $app" >&2; exit 1; }

if pgrep -x Lectern >/dev/null; then
  echo "Quit Lectern before installing." >&2
  exit 1
fi

# Replace atomically: copy next to the destination first, then swap.
staging="/Applications/.Lectern.app.installing"
rm -rf "$staging"
ditto "$app" "$staging"
rm -f "$staging/Contents/MacOS/LecternHarness"   # self-test alias, not part of the app
rm -rf /Applications/Lectern.app
mv "$staging" /Applications/Lectern.app
echo "Installed /Applications/Lectern.app"
