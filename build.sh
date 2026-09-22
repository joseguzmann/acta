#!/bin/bash
# Builds Acta and assembles the .app. No Xcode project needed, just its tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="Acta.app"
BIN="$APP/Contents/MacOS/Acta"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Xcode refuses to compile anything until its licence has been accepted, which
# needs sudo and a terminal. The Command Line Tools carry the same compiler and
# SDK without that gate, so fall back to them rather than stopping the build for
# a legal prompt — this also lets the project build on a Mac with no Xcode.
if ! swiftc --version >/dev/null 2>&1; then
  if [ -d /Library/Developer/CommandLineTools ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    echo "Xcode unavailable; building with the Command Line Tools"
  else
    echo "no usable Swift toolchain: accept the Xcode licence (sudo xcodebuild -license)"
    echo "or install the Command Line Tools (xcode-select --install)"
    exit 1
  fi
fi

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
  <key>NSAudioCaptureUsageDescription</key><string>Acta records the call audio so it can transcribe what the other people say. Nothing leaves this Mac.</string>
</dict>
</plist>
PLIST

# Sign with a real development identity when there is one.
#
# This matters more than it looks: macOS ties privacy permissions to the code
# signature. An ad-hoc signature changes on every build, so every rebuild looks
# like a brand new app and the screen-recording permission you just granted no
# longer applies — the app then fails to capture system audio while System
# Settings cheerfully shows it as allowed.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')

if [ -n "$IDENTITY" ]; then
  echo "signing as: $IDENTITY"
  codesign --force --options runtime \
    --entitlements Acta.entitlements \
    --sign "$IDENTITY" "$APP"
else
  echo "no development identity found; signing ad-hoc"
  echo "  (the system audio permission will need re-granting after each build)"
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "ready: $APP"
