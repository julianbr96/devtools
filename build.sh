#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/../CSWAP.app"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/cswap-build.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -parse-as-library -O \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$BUILD/ModuleCache" \
  "$ROOT/Sources/LocalData.swift" "$ROOT/Sources/Models.swift" "$ROOT/Sources/CLI.swift" \
  "$ROOT/Sources/Store.swift" "$ROOT/Sources/App.swift" \
  "$ROOT/Sources/LocalViews.swift" "$ROOT/Sources/Review.swift" "$ROOT/Sources/MenuBar.swift" \
  -o "$BUILD/CSWAP"
cp "$BUILD/CSWAP" "$APP/Contents/MacOS/CSWAP"
cp "$ROOT/Resources/demo.json" "$APP/Contents/Resources/demo.json"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>CSWAP</string>
<key>CFBundleDisplayName</key><string>CSWAP</string>
<key>CFBundleIdentifier</key><string>local.cswap.desktop</string>
<key>CFBundleVersion</key><string>5</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleExecutable</key><string>CSWAP</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
swiftc -module-cache-path "$BUILD/ModuleCache" "$ROOT/Scripts/MakeIcon.swift" -o "$BUILD/make-icon"
mkdir -p "$BUILD/AppIcon.iconset"
"$BUILD/make-icon" "$BUILD/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
