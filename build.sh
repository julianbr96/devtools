#!/bin/bash
# Builds build/DevTools.app. With --install, also copies it to /Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/DevTools.app"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/devtools-build.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$ROOT/Sources" -name '*.swift' | sort)
swiftc -swift-version 5 -parse-as-library -O \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$BUILD/ModuleCache" \
  "${SOURCES[@]}" \
  -o "$BUILD/DevTools"
cp "$BUILD/DevTools" "$APP/Contents/MacOS/DevTools"
cp "$ROOT/Resources/cswap-demo.json" "$APP/Contents/Resources/cswap-demo.json"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>DevTools</string>
<key>CFBundleDisplayName</key><string>DevTools</string>
<key>CFBundleIdentifier</key><string>io.github.julianbr96.devtools</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleExecutable</key><string>DevTools</string>
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

if [[ "${1:-}" == "--install" ]]; then
  if pgrep -x DevTools >/dev/null; then
    echo "DevTools is running. Quit it from its menu-bar panel, then run ./build.sh --install again." >&2
    exit 1
  fi
  rm -rf /Applications/DevTools.app
  ditto "$APP" /Applications/DevTools.app
  echo "Installed /Applications/DevTools.app"
fi
