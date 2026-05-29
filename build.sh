#!/bin/bash
set -euo pipefail

# Command Code + Codex Desktop Widget - Build & Package
SDK=$(xcrun --sdk macosx --show-sdk-path)
BIN=".build/CommandCodeCodexWidget"
APP=".build/CommandCodeCodex.app"
CONTENTS="$APP/Contents"

mkdir -p .build

echo "Building..."
swiftc -sdk "$SDK" \
  -target arm64-apple-macos26.0 \
  -framework SwiftUI -framework AppKit -framework Combine -framework Foundation \
  -O \
  -o "$BIN" \
  Sources/Diag.swift \
  Sources/Models.swift \
  Sources/TokenExtractor.swift \
  Sources/DataFetcher.swift \
  Sources/CodexFetcher.swift \
  Sources/App.swift

echo "Packaging .app bundle..."
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/CommandCodeCodexWidget"

cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CommandCodeCodexWidget</string>
    <key>CFBundleDisplayName</key><string>Command Code + Codex Widget</string>
    <key>CFBundleIdentifier</key><string>com.commandcode.codex-desktop-widget</string>
    <key>CFBundleExecutable</key><string>CommandCodeCodexWidget</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cat > "$CONTENTS/PkgInfo" <<< 'APPL????'

echo "Done. Launch with: open $APP"
