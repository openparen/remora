#!/usr/bin/env bash
# Build, notarize and publish a release: Remora-<version>.dmg on the GitHub
# release v<version>, and the cask in the Homebrew tap (REMORA_TAP, default
# openparen/homebrew-tap), from a clean tree whose HEAD is pushed. The version is
# MARKETING_VERSION in project.yml. usage: scripts/release.sh
#
# Signs with the Developer ID in REMORA_SIGN_IDENTITY / REMORA_TEAM (as
# build-app.sh). Notarizes with the team's App Store Connect API key, read from
# REMORA_ASC_ENV (default ~/.appstoreconnect/zyz.env: ASC_KEY_ID, ASC_ISSUER_ID,
# ASC_KEY_PATH; the key is the team's, not per app, and only its path is passed).
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAILED: $*" >&2; exit 1; }

: "${REMORA_SIGN_IDENTITY:?set REMORA_SIGN_IDENTITY (e.g. \"Developer ID Application\")}"
: "${REMORA_TEAM:?set REMORA_TEAM}"
. "${REMORA_ASC_ENV:-$HOME/.appstoreconnect/zyz.env}"
[ -f "$ASC_KEY_PATH" ] || fail "no App Store Connect key at ASC_KEY_PATH"

version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
tag="v$version"
[ -n "$version" ] || fail "no MARKETING_VERSION in project.yml"
[ -z "$(git status --porcelain)" ] || fail "the tree isn't clean"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "HEAD isn't origin/main; push first"
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "tag $tag exists"
! gh release view "$tag" >/dev/null 2>&1 || fail "release $tag exists"

app=$(scripts/build-app.sh Release)

# signed with the Developer ID, a secure timestamp and the hardened runtime, and not debuggable
codesign --verify --deep --strict "$app" || fail "codesign --verify"
info=$(codesign -dvvv "$app" 2>&1)
grep -q "^Authority=Developer ID Application: .*($REMORA_TEAM)\$" <<<"$info" || fail "not signed with the Developer ID"
grep -q '^Timestamp=' <<<"$info" || fail "no secure timestamp"
flags=$(sed -n 's/.*flags=\(0x[0-9a-f]*\).*/\1/p' <<<"$info")
(( flags & 0x10000 )) || fail "no hardened runtime (flags $flags)"
! codesign -d --entitlements - "$app" 2>/dev/null | grep -q get-task-allow || fail "has get-task-allow"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version" ] || fail "Info.plist version isn't $version"
echo "ok  $app: Developer ID, timestamped, hardened runtime"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
notary=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
# notarize $1; on anything but Accepted, print Apple's log
notarize() {
  xcrun notarytool submit "$1" "${notary[@]}" --wait --output-format json >"$work/notary.json" || true
  local id status
  id=$(plutil -extract id raw -o - "$work/notary.json" 2>/dev/null || true)
  status=$(plutil -extract status raw -o - "$work/notary.json" 2>/dev/null || true)
  if [ "$status" != Accepted ]; then
    cat "$work/notary.json" >&2
    [ -z "$id" ] || xcrun notarytool log "$id" "${notary[@]}" >&2
    fail "notarization of $1: ${status:-no result} (submission ${id:-none})"
  fi
  echo "ok  notarized $1: submission $id"
}

# the app itself, stapled, so a copy dragged out of the DMG opens offline too
ditto -c -k --keepParent "$app" "$work/Remora.zip"
notarize "$work/Remora.zip"
xcrun stapler staple -q "$app"
xcrun stapler validate -q "$app"

# the DMG: the app and a link to /Applications to drag it onto
mkdir "$work/Remora"
ditto "$app" "$work/Remora/Remora.app"
ln -s /Applications "$work/Remora/Applications"
dmg="build/release/Remora-$version.dmg"
mkdir -p build/release
rm -f "$dmg"
hdiutil create -quiet -volname "Remora $version" -srcfolder "$work/Remora" -format UDZO "$dmg"
codesign --sign "$REMORA_SIGN_IDENTITY" --timestamp "$dmg"

notarize "$dmg"
xcrun stapler staple -q "$dmg"
xcrun stapler validate -q "$dmg"
spctl -a -vvv -t open --context context:primary-signature "$dmg" 2>&1 | tee "$work/spctl.txt"
grep -q 'source=Notarized Developer ID' "$work/spctl.txt" || fail "Gatekeeper doesn't accept $dmg as notarized"

git tag -a "$tag" -m "Remora $version"
git push -q origin "$tag"
# also as Remora.dmg: releases/latest/download/Remora.dmg, and so the site's /download, always gets the newest
cp "$dmg" "$work/Remora.dmg"
gh release create "$tag" "$dmg" "$work/Remora.dmg" --verify-tag --title "Remora $version" --generate-notes

# the Homebrew cask: the new version and the DMG's checksum
tap=${REMORA_TAP:-openparen/homebrew-tap}
sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
git clone -q "git@github.com:$tap.git" "$work/tap"
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$work/tap/Casks/remora.rb"
git -C "$work/tap" commit -qam "remora $version"
git -C "$work/tap" push -q
# the build itself isn't an install: left registered, it would compete for rmr:// links with the installed app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" || true
echo "Released $tag: $dmg (cask in $tap updated)"
