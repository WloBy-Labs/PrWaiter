#!/bin/zsh
set -euo pipefail

# 构建并签名 dist/PrWaiter.app。
#
# 签名是渐进的：
#   没有身份           -> ad-hoc（能跑，但每次构建签名都变）
#   CODESIGN_IDENTITY  -> 用该身份签（自签或 Developer ID 都行）
# 本地跑一次 scripts/bootstrap_local_signing.sh 就会自动带上稳定身份。

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PrWaiter"
SIGNING_ENV_PATH="${SIGNING_ENV_PATH:-$HOME/Library/Application Support/$APP_NAME/signing/signing.env}"

if [[ -f "$SIGNING_ENV_PATH" ]]; then
    source "$SIGNING_ENV_PATH"
fi

APP_VERSION="${APP_VERSION:-$(<"$ROOT_DIR/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date '+%Y%m%d%H%M%S')}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
CODESIGN_IDENTITY_NAME="${CODESIGN_IDENTITY_NAME:-$CODESIGN_IDENTITY}"
CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-}"
CODESIGN_KEYCHAIN_PASSWORD="${CODESIGN_KEYCHAIN_PASSWORD:-}"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"

mkdir -p "$ROOT_DIR/dist"

APP_DIR="$APP_DIR" APP_VERSION="$APP_VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
    "$ROOT_DIR/build.sh"

codesign_args=(--force)

if [[ -n "$CODESIGN_IDENTITY" ]]; then
    if [[ -n "$CODESIGN_KEYCHAIN" && -n "$CODESIGN_KEYCHAIN_PASSWORD" ]]; then
        security unlock-keychain -p "$CODESIGN_KEYCHAIN_PASSWORD" "$CODESIGN_KEYCHAIN" >/dev/null 2>&1 || true
    fi

    # Developer ID 是拿去公证的，要 hardened runtime 和安全时间戳；
    # 自签身份两者都用不上，加了反而签不过
    if [[ "${CODESIGN_HARDENED_RUNTIME:-auto}" == "auto" ]]; then
        case "$CODESIGN_IDENTITY_NAME" in
            *"Developer ID"*) codesign_args+=(--options runtime --timestamp) ;;
            *) codesign_args+=(--timestamp=none) ;;
        esac
    elif [[ "$CODESIGN_HARDENED_RUNTIME" == "1" ]]; then
        codesign_args+=(--options runtime --timestamp)
    else
        codesign_args+=(--timestamp=none)
    fi

    codesign_args+=(--sign "$CODESIGN_IDENTITY")
    [[ -n "$CODESIGN_KEYCHAIN" ]] && codesign_args+=(--keychain "$CODESIGN_KEYCHAIN")

    echo "用 ${CODESIGN_IDENTITY_NAME} 签名"
else
    codesign_args+=(--timestamp=none --sign -)
    echo "提示：走 ad-hoc 签名，每次构建的签名都不一样。"
    echo "     跑一次 scripts/bootstrap_local_signing.sh 可建立稳定的本地身份。"
fi

codesign "${codesign_args[@]}" "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "产出 $APP_DIR"
