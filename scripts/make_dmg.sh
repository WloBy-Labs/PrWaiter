#!/bin/zsh
set -euo pipefail

# 把 dist/PrWaiter.app 打包成带 /Applications 拖拽目标的 DMG。
# 先跑 scripts/package_app.sh。

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PrWaiter"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
APP_VERSION="${APP_VERSION:-$(plutil -extract CFBundleShortVersionString raw "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo dev)}"
DMG_PATH="$ROOT_DIR/dist/${APP_NAME}-${APP_VERSION}.dmg"
VOL_NAME="${VOL_NAME:-$APP_NAME $APP_VERSION}"

if [[ ! -d "$APP_DIR" ]]; then
    echo "Missing $APP_DIR. Run scripts/package_app.sh first." >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d /tmp/pr_waiter_dmg.XXXXXX)"
cleanup() { rm -rf "$STAGING_DIR"; }
trap cleanup EXIT

cp -R "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "Created $DMG_PATH"
