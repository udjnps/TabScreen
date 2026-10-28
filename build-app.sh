#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_DIR="/Applications/TabScreen.app"

echo "=== Building TabScreen Host (Release) ==="
cd "$DIR/mac-host"
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift build -c release

echo "=== Creating macOS App Bundle: $APP_DIR ==="
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$DIR/mac-host/.build/release/TabScreenHost" "$APP_DIR/Contents/MacOS/TabScreenHost"
chmod +x "$APP_DIR/Contents/MacOS/TabScreenHost"

echo "=== Generating App Icon ==="
python3 "$DIR/scripts/generate_icon.py"

echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>TabScreenHost</string>
    <key>CFBundleIdentifier</key>
    <string>com.tabscreen.host</string>
    <key>CFBundleName</key>
    <string>TabScreen</string>
    <key>CFBundleDisplayName</key>
    <string>TabScreen</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>TabScreen uses Bluetooth to ensure wireless display connectivity with your tablet.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>TabScreen uses Bluetooth to communicate with your tablet.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>TabScreen uses the local network to discover and stream display video to your Android tablet over Wi-Fi.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>TabScreen requires Screen Recording access to mirror your screen to your tablet.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>TabScreen requires microphone and audio capture access to stream your Mac audio to your tablet speakers.</string>
</dict>
</plist>
EOF

echo "=== Signing TabScreen.app ==="
codesign --force --deep -s - --identifier "com.tabscreen.host" --requirements '=designated => identifier "com.tabscreen.host"' "$APP_DIR"

echo "=== Registering with macOS LaunchServices ==="
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" || true

echo "=== TabScreen.app successfully built, signed, and registered! ==="
