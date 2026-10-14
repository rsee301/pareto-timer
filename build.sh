#!/bin/bash
#
# Builds ParetoTimer.app from ParetoTimer.swift and installs it to /Applications.
# Requires Xcode Command Line Tools (run `xcode-select --install` once if missing).
#
#   bash build.sh                  build, install to /Applications, launch
#   bash build.sh ~/Applications   build, install there, launch
#   bash build.sh --no-install     build ParetoTimer.app here only (used by CI)
#
# VERSION=1.2.0 bash build.sh sets the version in Info.plist (default 1.0).
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ParetoTimer"
APP_DIR="$APP_NAME.app"
VERSION="${VERSION:-1.0}"
INSTALL=1
DEST="/Applications"
case "${1:-}" in
  --no-install) INSTALL=0 ;;
  "") ;;
  *) DEST="$1" ;;
esac

echo "==> Checking for swiftc"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools first:"
  echo "    xcode-select --install"
  exit 1
fi

echo "==> Compiling (universal: arm64 + x86_64)"
rm -rf "$APP_DIR" build
mkdir -p build
# Swift only allows top-level statements in a file called main.swift.
cp "$APP_NAME.swift" build/main.swift
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos11.0" -o "build/$APP_NAME-$arch" build/main.swift
done
lipo -create -output "build/$APP_NAME" "build/$APP_NAME-arm64" "build/$APP_NAME-x86_64"

echo "==> Assembling app bundle"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
mv "build/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
rm -rf build

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pareto Timer</string>
  <key>CFBundleDisplayName</key><string>Pareto Timer</string>
  <key>CFBundleExecutable</key><string>ParetoTimer</string>
  <key>CFBundleIdentifier</key><string>com.kyrosspace.paretotimer</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || \
  echo "    (ad-hoc signing skipped, the app will still run)"

if [ "$INSTALL" -eq 0 ]; then
  echo
  echo "Built $APP_DIR (version $VERSION)."
elif [ -w "$DEST" ]; then
  echo "==> Installing to $DEST"
  rm -rf "${DEST:?}/$APP_DIR"
  cp -R "$APP_DIR" "$DEST/"
  echo "==> Launching"
  open "$DEST/$APP_DIR"
  echo
  echo "Done. Look for the timer icon in your menu bar."
else
  echo
  echo "Built $APP_DIR here. Drag it to /Applications, then double-click it."
fi
