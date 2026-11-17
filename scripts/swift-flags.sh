# Shared by build.sh and scripts/release.sh (source it from the repository root).
# The app is one Swift module; its sources are grouped in folders under Sources/App.
SWIFT_FLAGS=(-parse-as-library -swift-version 5 -O -wmo)

# Every app source file, one path per line, in a stable order.
# File names must be unique across folders (build.sh compiles a flat snapshot).
app_sources() {
  find Sources/App -name '*.swift' | LC_ALL=C sort
}
