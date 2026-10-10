#!/bin/bash
# Builds "iCloud Cleaner.app". Run `./build.sh install` to also copy it to ~/Applications and open it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/iCloud Cleaner.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ICloudCleaner "$APP/Contents/MacOS/ICloudCleaner"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>iCloud Cleaner</string>
    <key>CFBundleDisplayName</key><string>iCloud Cleaner</string>
    <key>CFBundleIdentifier</key><string>local.icloudcleaner</string>
    <key>CFBundleExecutable</key><string>ICloudCleaner</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    mkdir -p ~/Applications
    pkill -x ICloudCleaner || true
    rm -rf ~/Applications/"iCloud Cleaner.app"
    cp -R "$APP" ~/Applications/
    open ~/Applications/"iCloud Cleaner.app"
    echo "Installed to ~/Applications and launched"
fi
