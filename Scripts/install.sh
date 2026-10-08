#!/bin/zsh
# Builds a Release Lectern.app and installs it to /Applications (replacing an existing copy).
# Usage: Scripts/install.sh
#
# The replacement keeps the previous app until the new one is in place and verified, and puts it
# back if anything fails, so a failed install never leaves /Applications without a Lectern.
#
# Overrides, for testing the installer without touching /Applications:
#   LECTERN_INSTALL_DIR        directory to install into (default /Applications)
#   LECTERN_APP                an already-built Lectern.app to install (skips the build)
#   LECTERN_SKIP_SIGNATURE_CHECK=1   verify only that the bundle has its executable (unsigned test bundles)
set -euo pipefail
cd "$(dirname "$0")/.."

dest_dir="${LECTERN_INSTALL_DIR:-/Applications}"
app="${LECTERN_APP:-}"
if [[ -z "$app" ]]; then
  Scripts/build.sh DD-release Release
  app="build/DD-release/Build/Products/Release/Lectern.app"
fi
[[ -d "$app" ]] || { echo "Build did not produce $app" >&2; exit 1; }

if [[ "$dest_dir" == "/Applications" ]] && pgrep -x Lectern >/dev/null; then
  echo "Quit Lectern before installing." >&2
  exit 1
fi
[[ -d "$dest_dir" ]] || { echo "Install directory $dest_dir does not exist." >&2; exit 1; }

final="$dest_dir/Lectern.app"
staging="$dest_dir/.Lectern.app.installing"
previous="$dest_dir/.Lectern.app.previous"

# A bundle is good when it has its executable and, unless skipped, a valid signature.
verify_bundle() {
  [[ -x "$1/Contents/MacOS/Lectern" ]] || return 1
  [[ "${LECTERN_SKIP_SIGNATURE_CHECK:-0}" == 1 ]] || codesign --verify --deep --strict "$1" 2>/dev/null
}

# Copy next to the destination first, and check the copy before anything is replaced.
rm -rf "$staging" "$previous"
ditto "$app" "$staging" || { rm -rf "$staging"; echo "Copying the app to $dest_dir failed; nothing was changed." >&2; exit 1; }
rm -f "$staging/Contents/MacOS/LecternHarness"   # self-test alias, not part of the app
if ! verify_bundle "$staging"; then
  rm -rf "$staging"
  echo "The new app failed verification; nothing was changed." >&2
  exit 1
fi

# Swap with two renames, keeping the old app aside until the new one is verified in place.
had_previous=0
if [[ -e "$final" ]]; then
  mv "$final" "$previous" || { rm -rf "$staging"; echo "Couldn't move the installed app aside; nothing was changed." >&2; exit 1; }
  had_previous=1
fi

restore_previous() {
  rm -rf "$final"
  if [[ $had_previous == 1 ]]; then
    mv "$previous" "$final" || { echo "Couldn't restore the previous app; it is at $previous." >&2; return 1; }
  fi
}

if ! mv "$staging" "$final"; then
  rm -rf "$staging"
  restore_previous || exit 1
  echo "Installing failed; the previous Lectern was restored." >&2
  exit 1
fi
if ! verify_bundle "$final"; then
  restore_previous || exit 1
  echo "The installed app failed verification; the previous Lectern was restored." >&2
  exit 1
fi
rm -rf "$previous"
echo "Installed $final"
