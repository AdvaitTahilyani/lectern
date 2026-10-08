#!/bin/zsh
# Tests build.sh's signing/diagnostics handling and install.sh's atomic replacement against
# temporary directories and stand-in tools. Touches neither /Applications nor a real build.
# Usage: Scripts/test-scripts.sh
set -uo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"; for d in "$root"/build/DD-scripttest-*(N); do rm -rf "$d"; done' EXIT
failures=0
check() { if eval "$2"; then print "ok   $1"; else print "FAIL $1"; failures=$((failures + 1)); fi }

fake_bundle() {   # $1 = dir to create Lectern.app in, $2 = marker text
  mkdir -p "$1/Lectern.app/Contents/MacOS"
  printf '#!/bin/sh\n' > "$1/Lectern.app/Contents/MacOS/Lectern"; chmod +x "$1/Lectern.app/Contents/MacOS/Lectern"
  print -r -- "$2" > "$1/Lectern.app/marker"
}

# ---------------- install.sh ----------------
export LECTERN_SKIP_SIGNATURE_CHECK=1
new="$work/new"; fake_bundle "$new" "new"

dest="$work/dest-fresh"; mkdir -p "$dest"
LECTERN_INSTALL_DIR="$dest" LECTERN_APP="$new/Lectern.app" Scripts/install.sh >/dev/null 2>&1
check "install into an empty directory" '[[ "$(cat $dest/Lectern.app/marker)" == new ]]'

dest="$work/dest-replace"; mkdir -p "$dest"; fake_bundle "$dest" "old"
LECTERN_INSTALL_DIR="$dest" LECTERN_APP="$new/Lectern.app" Scripts/install.sh >/dev/null 2>&1
check "replacing an installed app" '[[ "$(cat $dest/Lectern.app/marker)" == new ]]'
check "no staging or previous copies are left behind" '[[ -z "$(ls -A $dest | grep -v "^Lectern.app$")" ]]'

dest="$work/dest-broken-new"; mkdir -p "$dest"; fake_bundle "$dest" "old"
broken="$work/broken"; mkdir -p "$broken/Lectern.app"   # no executable: fails verification
LECTERN_INSTALL_DIR="$dest" LECTERN_APP="$broken/Lectern.app" Scripts/install.sh >/dev/null 2>&1; rc=$?
check "a new app that fails verification is refused" '[[ $rc -ne 0 ]]'
check "and the installed app is untouched" '[[ "$(cat $dest/Lectern.app/marker)" == old ]]'

# A move that fails after the old app was set aside: a stand-in `mv` refuses to put the new app in place.
dest="$work/dest-mv-fails"; mkdir -p "$dest"; fake_bundle "$dest" "old"
bin="$work/bin-mv"; mkdir -p "$bin"
cat > "$bin/mv" <<'MV'
#!/bin/sh
case "$1" in *.Lectern.app.installing) echo "mv: simulated failure" >&2; exit 1;; esac
exec /bin/mv "$@"
MV
chmod +x "$bin/mv"
PATH="$bin:$PATH" LECTERN_INSTALL_DIR="$dest" LECTERN_APP="$new/Lectern.app" Scripts/install.sh >/dev/null 2>&1; rc=$?
check "a failed final move reports failure" '[[ $rc -ne 0 ]]'
check "and the previous app is restored" '[[ "$(cat $dest/Lectern.app/marker)" == old ]]'
check "and nothing is left aside" '[[ -z "$(ls -A $dest | grep -v "^Lectern.app$")" ]]'

# ---------------- build.sh ----------------
tools="$work/tools"; mkdir -p "$tools"
cat > "$tools/xcodegen" <<'T'
#!/bin/sh
exit 0
T
cat > "$tools/xcodebuild" <<'T'
#!/bin/sh
# Stand-in: succeeds and creates the app bundle in the derived data folder, or fails when told to.
dd=""; prev=""
for a in "$@"; do [ "$prev" = "-derivedDataPath" ] && dd="$a"; prev="$a"; done
if [ -n "$FAKE_XCODEBUILD_FAIL" ]; then
  echo "/x/SourcePackages/checkouts/dep/File.swift:1:1: error: only a dependency failed"
  echo "** BUILD FAILED **"; exit 65
fi
mkdir -p "$dd/Build/Products/Debug/Lectern.app/Contents/MacOS"
echo "** BUILD SUCCEEDED **"
T
cat > "$tools/security" <<'T'
#!/bin/sh
echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Lectern Local Signing"'
T
cat > "$tools/codesign" <<'T'
#!/bin/sh
case "$1" in --verify) exit "${FAKE_VERIFY_STATUS:-0}";; esac
echo "codesign: simulated signing failure" >&2
exit "${FAKE_CODESIGN_STATUS:-0}"
T
chmod +x "$tools"/*

out=$(PATH="$tools:$PATH" FAKE_CODESIGN_STATUS=1 Scripts/build.sh DD-scripttest-sign 2>&1); rc=$?
check "a signing failure fails the build" '[[ $rc -ne 0 ]]'
check "and is never reported as signed" '[[ "$out" != *"Signed with Lectern Local Signing"* ]]'
check "and its message is shown" '[[ "$out" == *"simulated signing failure"* ]]'

out=$(PATH="$tools:$PATH" Scripts/build.sh DD-scripttest-ok 2>&1); rc=$?
check "a successful signing build succeeds" '[[ $rc -eq 0 && "$out" == *"Signed with Lectern Local Signing"* ]]'

out=$(PATH="$tools:$PATH" FAKE_VERIFY_STATUS=1 Scripts/build.sh DD-scripttest-verify 2>&1); rc=$?
check "a signature that does not verify fails the build" '[[ $rc -ne 0 ]]'

out=$(PATH="$tools:$PATH" FAKE_XCODEBUILD_FAIL=1 Scripts/build.sh DD-scripttest-fail 2>&1); rc=$?
check "a build that failed only in a dependency still shows why" '[[ $rc -ne 0 && "$out" == *"only a dependency failed"* ]]'

(( failures == 0 )) && print "all script tests passed" || { print "$failures script test(s) failed"; exit 1; }
