#!/bin/bash
# Builds Orbit.app next to this script. Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="Orbit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Orbit" "$APP/Contents/MacOS/Orbit"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Orbit</string>
    <key>CFBundleDisplayName</key><string>Orbit</string>
    <key>CFBundleIdentifier</key><string>app.orbit.dropring</string>
    <key>CFBundleExecutable</key><string>Orbit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>Orbit saves converted files next to the originals.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Orbit saves converted files next to the originals.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Orbit saves converted files next to the originals.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/$APP"
fi
