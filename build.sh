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

# 有稳定签名身份就用它签，没有就退回 ad-hoc。
#
# 这不是可有可无的：**macOS 不给 ad-hoc 签名的 app 发通知权限** ——
# requestAuthorization 直接返回 granted=false（UNErrorDomain error 1），
# 而且系统设置的通知列表里根本不会出现这个 app。ad-hoc 签名每次构建都变，
# 系统没法把授权记在一个稳定身份上。实测同一份代码：
#   ad-hoc 签名        -> granted=false, alertStyle=0
#   PrWaiter Signing   -> granted=true,  alertStyle=1（横幅）
# 所以要调通知，得先跑一次 scripts/bootstrap_local_signing.sh。
# bootstrap_local_signing.sh 默认把身份放进 login 钥匙串，名字是「PrWaiter Local Signing」；
# CI 用的是「PrWaiter Signing」。两个都认，谁在就用谁。
signed=""
for name in "${CODESIGN_IDENTITY_NAME:-}" "PrWaiter Local Signing" "PrWaiter Signing"; do
    [ -n "$name" ] || continue
    if security find-identity 2>/dev/null | grep -q "$name"; then
        if codesign --force --timestamp=none -s "$name" "$APP" >/dev/null 2>&1; then
            echo "已用「${name}」签名（通知功能需要稳定身份）"
            signed=1
            break
        fi
    fi
done

if [ -z "$signed" ]; then
    codesign --force -s - "$APP" >/dev/null 2>&1 || true
    echo "提醒：ad-hoc 签名 —— 这样构建出来的包拿不到通知权限。"
    echo "      要调通知先跑一次：scripts/bootstrap_local_signing.sh"
fi

echo "OK: $APP v$APP_VERSION"
