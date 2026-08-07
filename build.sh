#!/bin/bash
# 编译出 PrWaiter.app（只需要 Command Line Tools，不需要 Xcode 工程）
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
APP=PrWaiter.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PrWaiter</string>
    <key>CFBundleDisplayName</key><string>PrWaiter</string>
    <key>CFBundleIdentifier</key><string>me.xining.prwaiter</string>
    <key>CFBundleExecutable</key><string>PrWaiter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# 版本号只在 VERSION 文件里维护，App 运行时从 Info.plist 读取
swiftc -O -swift-version 5 -parse-as-library \
    -o "$APP/Contents/MacOS/PrWaiter" PrWaiter.swift

echo "OK: $APP v$VERSION （open $APP 运行）"
