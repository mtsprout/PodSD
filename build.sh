#!/bin/zsh
# Builds PodSD.app next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=PodSD.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
cp .build/release/PodSD $APP/Contents/MacOS/PodSD
mkdir -p $APP/Contents/Resources
cp assets/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>PodSD</string>
<key>CFBundleExecutable</key><string>PodSD</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>local.podsd</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --sign - $APP >/dev/null 2>&1 || true
echo "Built $(pwd)/$APP"
