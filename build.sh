#!/bin/bash
# Builds "Don't Fret.app" into ./build using only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Don't Fret.app"
mkdir -p build
echo "→ Compiling…"
# compile a snapshot of the sources, so edits made while building can't break it halfway
SNAP="$(mktemp -d)"
cp Sources/App/*.swift "$SNAP/"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" -O \
  "$SNAP"/*.swift -o build/DontFret
rm -rf "$SNAP"
echo "→ Bundling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/DontFret "$APP/Contents/MacOS/DontFret"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Don’t Fret listens to your guitar to check the chords and strums you play, to tune your strings, and to record you in the Studio.</string>
  <key>NSCameraUsageDescription</key><string>Don’t Fret uses the camera when you record a video of yourself playing in the Studio.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Don’t Fret listens to a song while it plays on your Mac, so it can work out the chords for the whole song. Nothing is recorded or saved.</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ Built $APP"
