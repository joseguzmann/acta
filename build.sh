#!/bin/bash
# Builds Acta and assembles the .app. No Xcode project needed, just its tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="Acta.app"
BIN="$APP/Contents/MacOS/Acta"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "building…"
swiftc -O -parse-as-library \
  -target arm64-apple-macos26.0 \
  -framework SwiftUI -framework AppKit -framework Speech \
  -framework AVFoundation -framework CoreAudio -framework UserNotifications \
  Sources/*.swift -o "$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Acta</string>
  <key>CFBundleDisplayName</key><string>Acta</string>
  <key>CFBundleIdentifier</key><string>dev.joseguzman.acta</string>
  <key>CFBundleExecutable</key><string>Acta</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Acta transcribes your voice during the meeting. The audio never leaves this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Acta uses on-device speech recognition. Nothing is sent anywhere.</string>
  <key>NSAppleEventsUsageDescription</key><string>Acta reads your browser tab URLs to notice when you join a meeting.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "ready: $APP"
