#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

cd "$ROOT"
sh "$ROOT/scripts/build-audio-tap.sh"
swift build -c debug

BIN_DIR=$(swift build -c debug --show-bin-path)
APP="$ROOT/dist/Phone.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Phone" "$APP/Contents/MacOS/Phone"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Phone</string>
  <key>CFBundleIdentifier</key><string>local.phone.mini</string>
  <key>CFBundleName</key><string>Phone</string>
  <key>CFBundleDisplayName</key><string>Phone</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Phone needs the microphone for SIP calls.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Phone transcribes calls locally on this Mac.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Phone call</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>tel</string>
        <string>callto</string>
        <string>sip</string>
      </array>
    </dict>
  </array>
</dict></plist>
PLIST

# Ad-hoc signing is sufficient for a local development build.
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
