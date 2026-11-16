#!/bin/bash
# Builds a universal (Apple Silicon + Intel) "Don't Fret.app" and packages it for download:
#   release/DontFret-<version>.dmg   (open it and drag the app to Applications)
#   release/DontFret-<version>.zip
# Usage: scripts/release.sh 1.1
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version>, e.g. 1.1}"
APP="build/Don't Fret.app"
FLAGS=(-parse-as-library -swift-version 5 -O)

echo "→ Building the app bundle…"
./build.sh

for arch in arm64 x86_64; do
  echo "→ Compiling for $arch…"
  swiftc "${FLAGS[@]}" -target "$arch-apple-macos14.0" Sources/App/*.swift -o "build/DontFret-$arch"
done
echo "→ Making a universal binary…"
lipo -create -output "$APP/Contents/MacOS/DontFret" build/DontFret-arm64 build/DontFret-x86_64
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "→ Packaging…"
rm -rf release/stage && mkdir -p release/stage
ditto "$APP" "release/stage/Don't Fret.app"
ln -s /Applications release/stage/Applications
rm -f "release/DontFret-$VERSION.dmg" "release/DontFret-$VERSION.zip"
hdiutil create -quiet -volname "Don't Fret $VERSION" -srcfolder release/stage -ov -format UDZO "release/DontFret-$VERSION.dmg"
ditto -c -k --keepParent "$APP" "release/DontFret-$VERSION.zip"
rm -rf release/stage

lipo -archs "$APP/Contents/MacOS/DontFret"
ls -lh release/
echo "✓ Release $VERSION ready in ./release"
echo "  Publish it with: gh release create v$VERSION release/DontFret-$VERSION.dmg release/DontFret-$VERSION.zip --title \"Don't Fret $VERSION\" --generate-notes"
