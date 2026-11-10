#!/usr/bin/env bash
# Assemble SundayKeys.app from the Swift package's release build.
#
# Usage:
#   tools/bundle_app.sh                build the release product, then bundle
#   tools/bundle_app.sh --no-build     bundle a binary that is already built
#   tools/bundle_app.sh --out DIR      write the bundle into DIR (default: build)
#
# Verification status: this script runs on the macOS runner in
# .github/workflows/build.yml, which lints the Info.plist, checks the executable
# and verifies the signature on every push to main. It has not been opened on a
# screen: launching the bundle, hearing it and using a controller still need the
# Mac, so treat launch behaviour as unverified until that has happened.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

build=1
out=build
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) build=0; shift ;;
    --out) out="${2:?--out needs a directory}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 64 ;;
  esac
done

name="SundayKeys"
executable="SundayKeysApp"
# This implementation's own identity. The analysis documents the original app as
# bundle id com.sundaysounds.sundaykeys, version 2.5.2, build 3367; nothing here
# claims to be that bundle, and the identifier is deliberately different so the
# two can be installed side by side.
identifier="com.worshipwarehouse.sundaykeys-cleanroom"
bundle_version="0.5.0"
bundle_build="5"

if [[ "$build" -eq 1 ]]; then
  swift build -c release --product "$executable"
fi

binary=".build/release/$executable"
if [[ ! -x "$binary" ]]; then
  printf 'no release binary at %s; run swift build -c release\n' "$binary" >&2
  exit 1
fi

app="$out/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/$executable"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$executable</string>
    <key>CFBundleIdentifier</key>
    <string>$identifier</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundleDisplayName</key>
    <string>Sunday Keys</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$bundle_version</string>
    <key>CFBundleVersion</key>
    <string>$bundle_build</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$app/Contents/PkgInfo"

# Ad-hoc signing, so the bundle launches on Apple silicon without a developer
# certificate. This is not distribution signing and nothing here is notarised.
codesign --force --sign - "$app" >/dev/null

# Verify what was assembled instead of assuming it: any failed check exits.
plutil -lint "$app/Contents/Info.plist" >/dev/null
[[ -x "$app/Contents/MacOS/$executable" ]]
codesign --verify --strict "$app"
[[ "$(plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")" == "$executable" ]]

printf '\n%s\n' "$app"
printf '  executable  %s\n' "$(file -b "$app/Contents/MacOS/$executable")"
printf '  identifier  %s\n' "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")"
printf '  version     %s (%s)\n' \
  "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" \
  "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
printf '  signature   ad-hoc\n'
printf '  size        %s\n' "$(du -sh "$app" | cut -f1)"
printf '\nOpen it with: open %s\n' "$app"
