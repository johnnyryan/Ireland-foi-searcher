#!/bin/bash
# Builds "FOI Search.app" (Apple Silicon, macOS 12+).
# By Johnny Ryan. Free and open source under the MIT License (see LICENSE).
# Needs only Apple's Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP="../FOI Search.app"
BUILD=.build
rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos12.0 \
  -framework Cocoa -framework WebKit -framework PDFKit -framework Vision -lsqlite3 \
  main.swift -o "$APP/Contents/MacOS/FOI Search"

# icon
swiftc -swift-version 5 -framework Cocoa makeicon.swift -o "$BUILD/makeicon"
mkdir -p "$BUILD/AppIcon.iconset"
"$BUILD/makeicon" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FOI Search</string>
  <key>CFBundleDisplayName</key><string>FOI Search</string>
  <key>CFBundleExecutable</key><string>FOI Search</string>
  <key>CFBundleIdentifier</key><string>ie.foisearch.app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.reference</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Johnny Ryan. Free and open source under the MIT License.</string>
</dict></plist>
PLIST

cp LICENSE README.md "$APP/Contents/Resources/"

codesign --force --deep --sign - "$APP"
echo "Built: $(cd .. && pwd)/FOI Search.app"
