#!/usr/bin/env bash
# Builds "build/UsageBar.app": release binary, Info.plist, icon, ad-hoc signature.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="UsageBar"
BUNDLE_ID="${BUNDLE_ID:-com.icarus2419.UsageBar}"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
ICNS="$BUILD_DIR/AppIcon.icns"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Universal releases must be built on an Apple Silicon Mac." >&2
    exit 1
  fi
  swift build -c release --product UsageBar
  ARM_BIN="$(swift build -c release --show-bin-path)/UsageBar"
  swift build -c release --product UsageBar \
    --triple x86_64-apple-macosx13.0 \
    --scratch-path "$ROOT/.build/intel"
  INTEL_BIN="$ROOT/.build/intel/x86_64-apple-macosx/release/UsageBar"
else
  swift build -c release --product UsageBar
  BIN="$(swift build -c release --show-bin-path)/UsageBar"
fi

if [[ ! -f "$ICNS" || "scripts/make-icon.swift" -nt "$ICNS" ]]; then
  echo "Rendering icon…"
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$BUILD_DIR"
  swift scripts/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$ICONSET"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP/Contents/MacOS/UsageBar"
  lipo "$APP/Contents/MacOS/UsageBar" -verify_arch arm64 x86_64
else
  cp "$BIN" "$APP/Contents/MacOS/UsageBar"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>UsageBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Your AI plan limits, at a glance.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP"
