#!/usr/bin/env bash
# Build Remora.app and print its path. usage: scripts/build-app.sh [Debug|Release]
#
# REMORA_SIGN_IDENTITY (and REMORA_TEAM) sign with a real identity, e.g.
#   REMORA_SIGN_IDENTITY="Developer ID Application" REMORA_TEAM=ABCDE12345 scripts/build-app.sh
# Unset, the app is ad-hoc signed and macOS asks for Keychain access after
# every rebuild, because each build looks like a new app.
#
# Builds into REMORA_DERIVED_DATA (default ~/Library/Developer/Xcode/DerivedData/Remora-local):
# never in-tree, which breaks on a network share, and never under /tmp, where
# macOS won't register the app's rmr:// scheme.
set -euo pipefail
cd "$(dirname "$0")/.."
config=${1:-Debug}
case "$config" in Debug|Release) ;; *) echo "usage: scripts/build-app.sh [Debug|Release]" >&2; exit 2 ;; esac
dd=${REMORA_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Remora-local}
mkdir -p "$dd"

xcodegen generate --quiet
signing=()
if [ -n "${REMORA_SIGN_IDENTITY:-}" ]; then
  signing=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$REMORA_SIGN_IDENTITY" "DEVELOPMENT_TEAM=${REMORA_TEAM:-}")
  # a release is notarized, which wants a secure timestamp and no debugger entitlement
  # (xcodebuild build injects get-task-allow in every configuration; only an archive leaves it out)
  [ "$config" = Release ] && signing+=(OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

log="$dd/build.log"
if ! xcodebuild -project Remora.xcodeproj -scheme Remora -configuration "$config" -derivedDataPath "$dd" \
    ${signing[@]+"${signing[@]}"} build >"$log" 2>&1; then
  grep -E "error:" "$log" >&2 || tail -20 "$log" >&2
  echo "build failed; full log: $log" >&2
  exit 1
fi
grep -E "warning: " "$log" | grep -v "Metadata extraction skipped" >&2 || true
app="$dd/Build/Products/$config/Remora.app"
[ -d "$app" ] || { echo "build succeeded but $app is missing" >&2; exit 1; }
echo "$app"
