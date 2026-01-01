#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔨 Building EzPlayer..."

# Compile Swift source with optimization
swiftc -o EzPlayer Sources/main.swift \
  -framework Cocoa \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework Accelerate \
  -O

# Create app bundle structure
rm -rf EzPlayer.app
mkdir -p EzPlayer.app/Contents/MacOS
mkdir -p EzPlayer.app/Contents/Resources
mv EzPlayer EzPlayer.app/Contents/MacOS/

# Create Info.plist
cat > EzPlayer.app/Contents/Info.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>EzPlayer</string>
    <key>CFBundleIdentifier</key>
    <string>com.ezplayer.app</string>
    <key>CFBundleName</key>
    <string>EzPlayer</string>
    <key>CFBundleDisplayName</key>
    <string>EzPlayer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>mp3</string>
                <string>wav</string>
                <string>m4a</string>
                <string>aac</string>
                <string>aiff</string>
                <string>flac</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>Audio File</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "Built successfully: EzPlayer.app"
echo ""
echo "Location: $SCRIPT_DIR/EzPlayer.app"
echo ""
echo "Next steps:"
echo "  1. (Optional) Move to Applications: mv EzPlayer.app ~/Applications/"
echo "  2. Set up Raycast script: Add Scripts/ folder to Raycast Script Commands"
echo ""

