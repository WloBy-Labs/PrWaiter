#!/bin/bash
# 编译出 PrWaiter.app（只需要 Command Line Tools，不需要 Xcode 工程）
#
# 默认产出仓库根目录下的 PrWaiter.app，供开发时 open 就跑。
# 打包脚本会用 APP_DIR / APP_VERSION / BUILD_NUMBER 覆盖，产出 dist/ 里那份。
set -euo pipefail
cd "$(dirname "$0")"

APP_VERSION="${APP_VERSION:-$(cat VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$APP_VERSION}"
APP="${APP_DIR:-PrWaiter.app}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 图标由 make-icon.swift 现画，不往仓库里塞二进制资产
ICONSET="$(mktemp -d)/PrWaiter.iconset"
swift make-icon.swift "$ICONSET" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/PrWaiter.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PrWaiter</string>
    <key>CFBundleDisplayName</key><string>PrWaiter</string>
    <key>CFBundleIdentifier</key><string>me.xining.prwaiter</string>
    <key>CFBundleExecutable</key><string>PrWaiter</string>
    <key>CFBundleIconFile</key><string>PrWaiter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# 版本号只在 VERSION 文件里维护，App 运行时从 Info.plist 读取
swiftc -O -swift-version 5 -parse-as-library \
    -o "$APP/Contents/MacOS/PrWaiter" PrWaiter.swift

echo "OK: $APP v$APP_VERSION"
