#!/bin/bash
# Builds a sandboxed, universal "Don't Fret.app" for the Mac App Store, signs it,
# packages it as release/DontFret-<version>-<build>.pkg and (with --upload) sends it
# to App Store Connect, where it shows up in TestFlight once processing finishes.
#
# Usage: scripts/appstore.sh <version> [build] [--upload]
#   e.g. scripts/appstore.sh 1.1            (build number defaults to a timestamp)
#        scripts/appstore.sh 1.1 3 --upload
#
# Signing uses whichever team member's certificates are in this Mac's keychain:
#   "Apple Distribution: <name> (9A9HR6WT4K)" and "3rd Party Mac Developer Installer: <name> (9A9HR6WT4K)"
# (Xcode → Settings → Accounts → Manage Certificates creates both). SIGN_NAME picks one if there are several.
#
# Upload, either:
#   an App Store Connect team API key in ~/.appstoreconnect/private_keys with
#     ASC_KEY_ID (default 65M28WPBKC) and ASC_ISSUER_ID (default: this team's issuer), or
#   your Apple ID: ASC_APPLE_ID=you@example.com and an app-specific password (appleid.apple.com)
#     saved once with: xcrun altool --store-password-in-keychain-item ASC_PASSWORD -u you@example.com -p <password>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/appstore.sh <version> [build] [--upload]}"
BUILD="$(date +%Y%m%d%H%M)"
UPLOAD=0
for a in "${@:2}"; do
  if [[ "$a" == "--upload" ]]; then UPLOAD=1; else BUILD="$a"; fi
done
ASC_KEY_ID="${ASC_KEY_ID:-65M28WPBKC}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-d03fc0f2-5b10-47df-8d20-26c8581af9ca}"
TEAM="9A9HR6WT4K"
# the first matching certificate for this team (narrowed by SIGN_NAME if set)
identity() {
  security find-identity -v | grep -F "\"$1: " | grep -F "($TEAM)\"" | grep -F "${SIGN_NAME:-}" \
    | head -1 | sed -E 's/.*"(.*)"/\1/'
}
APP_SIGN="$(identity "Apple Distribution")"
PKG_SIGN="$(identity "3rd Party Mac Developer Installer")"
[[ -n "$APP_SIGN" ]] || { echo "✗ No \"Apple Distribution: … ($TEAM)\" certificate in the keychain"; exit 1; }
[[ -n "$PKG_SIGN" ]] || { echo "✗ No \"3rd Party Mac Developer Installer: … ($TEAM)\" certificate in the keychain"; exit 1; }
OUT="build/appstore"
APP="$OUT/Don't Fret.app"
PKG="release/DontFret-$VERSION-$BUILD.pkg"
# APPSTORE turns off Songsterr chord-chart lookups (no licence for that data in the store build)
FLAGS=(-parse-as-library -swift-version 5 -O -D APPSTORE)

rm -rf "$OUT" && mkdir -p "$OUT" release
# build exactly what's committed, so unfinished work in the checkout never ships
SNAP="$(mktemp -d)"
git archive HEAD Sources/App | tar -x -C "$SNAP" && find "$SNAP/Sources/App" -name '*.swift' -exec mv {} "$SNAP/" \; && rm -rf "$SNAP/Sources"
echo "→ Building commit $(git rev-parse --short HEAD)"
for arch in arm64 x86_64; do
  echo "→ Compiling for $arch…"
  swiftc "${FLAGS[@]}" -target "$arch-apple-macos14.0" "$SNAP"/*.swift -o "$OUT/DontFret-$arch"
done
rm -rf "$SNAP"

echo "→ Bundling $VERSION ($BUILD)…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/DontFret" "$OUT/DontFret-arm64" "$OUT/DontFret-x86_64"
# the App Store requires a compiled asset catalog (Assets.car) holding the app icon
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$OUT/assets-partial.plist" >/dev/null
cp signing/embedded.provisionprofile "$APP/Contents/embedded.provisionprofile"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DontFret</string>
  <key>CFBundleIdentifier</key><string>app.dontfret.guitar</string>
  <key>CFBundleName</key><string>Don’t Fret</string>
  <key>CFBundleDisplayName</key><string>Don’t Fret</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Jeremy Zay</string>
  <key>NSMicrophoneUsageDescription</key><string>Don’t Fret listens to your guitar to check the chords and strums you play, to tune your strings, and to record you in the Studio.</string>
  <key>NSCameraUsageDescription</key><string>Don’t Fret uses the camera when you record a video of yourself playing in the Studio.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Don’t Fret listens to a song while it plays on your Mac, so it can work out the chords for the whole song. Nothing is recorded or saved.</string>
</dict>
</plist>
PLIST
rm -f "$OUT"/DontFret-*

echo "→ Signing as $APP_SIGN…"
codesign --force --options runtime --timestamp --sign "$APP_SIGN" \
  --entitlements signing/DontFret.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "→ Packaging…"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$PKG_SIGN" "$PKG"

if [[ $UPLOAD == 1 ]]; then
  if [[ -n "${ASC_APPLE_ID:-}" ]]; then
    AUTH=(-u "$ASC_APPLE_ID" -p "@keychain:ASC_PASSWORD")
  else
    AUTH=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
  fi
  echo "→ Validating with App Store Connect…"
  xcrun altool --validate-app -f "$PKG" -t macos "${AUTH[@]}"
  echo "→ Uploading…"
  xcrun altool --upload-app -f "$PKG" -t macos "${AUTH[@]}"
  echo "✓ Uploaded $VERSION ($BUILD). It appears in TestFlight once Apple finishes processing (usually 5–30 min)."
else
  echo "✓ Built $PKG  (add --upload to send it to App Store Connect)"
fi
