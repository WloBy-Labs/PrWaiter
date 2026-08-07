#!/bin/zsh
set -euo pipefail

# 生成一张固定的自签代码签名证书（不需要 Apple 开发者账号），并打印出要贴进
# GitHub Secrets 的值，好让每次发版都用同一个身份签名。
#
# 说清楚它能干什么、不能干什么：
#   能：每次发版的签名身份一致，App 在系统眼里始终是同一个东西；
#       校验完整性，二进制被改过会签名失效
#   不能：去掉 Gatekeeper 首次打开的警告 —— 那需要付费 Developer ID 加公证
#
# PrWaiter 不申请任何 TCC 权限（屏幕录制之类），所以这里没有「保住权限」
# 这一层收益；做稳定签名是为了身份一致，以及将来真要加权限时不用返工。
#
# 用法：
#   zsh scripts/make_signing_cert.sh
#
# 然后加到 Settings -> Secrets and variables -> Actions：
#   MACOS_CERT_P12       = 打印出来的 base64
#   MACOS_CERT_PASSWORD  = 打印出来的密码
#
# 产物落在 ~/Library/Application Support/PrWaiter/signing/ci/，**不是** dist/ ——
# dist/ 是构建输出目录，语义上随时可以清空，把长期密钥放那儿早晚会被误删。

APP_NAME="PrWaiter"
IDENTITY_NAME="${IDENTITY_NAME:-$APP_NAME Signing}"
OUT_DIR="${OUT_DIR:-$HOME/Library/Application Support/$APP_NAME/signing/ci}"
P12_PATH="$OUT_DIR/ci-signing.p12"
PASSWORD_PATH="$OUT_DIR/ci-signing.password"

# 这张证书的全部价值就在于「固定不变」。重跑一次就换了身份，之前发的版本
# 和新版本在系统看来是两个不同的 App。所以默认拒绝覆盖。
if [[ -f "$P12_PATH" && "${FORCE:-0}" != "1" ]]; then
    echo "已经有一张证书了：$P12_PATH" >&2
    echo >&2
    echo "没有覆盖它 —— 重新生成会换掉签名身份，装过旧版的用户在系统看来" >&2
    echo "等于装了个不同的 App。要看现有证书的 Secrets 值，跑：" >&2
    echo >&2
    echo "  base64 < '$P12_PATH'" >&2
    echo "  cat '$PASSWORD_PATH'" >&2
    echo >&2
    echo "确实要换新身份的话：FORCE=1 zsh scripts/make_signing_cert.sh" >&2
    exit 1
fi

P12_PASSWORD="${P12_PASSWORD:-$(openssl rand -base64 18 | tr -d '\n')}"

TEMP_DIR="$(mktemp -d /tmp/pr_waiter_cert.XXXXXX)"
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

cat > "$TEMP_DIR/openssl.cnf" <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = dn
x509_extensions = v3_codesign

[ dn ]
CN = $IDENTITY_NAME

[ v3_codesign ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

openssl req \
    -new -newkey rsa:2048 -x509 -sha256 -days 3650 -nodes \
    -config "$TEMP_DIR/openssl.cnf" \
    -keyout "$TEMP_DIR/key.pem" \
    -out "$TEMP_DIR/cert.pem" >/dev/null 2>&1

# macOS `security import` needs the legacy PKCS#12 encryption algorithms.
pkcs12_legacy_args=()
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
    pkcs12_legacy_args=(-legacy)
fi

openssl pkcs12 -export \
    "${pkcs12_legacy_args[@]}" \
    -inkey "$TEMP_DIR/key.pem" \
    -in "$TEMP_DIR/cert.pem" \
    -out "$P12_PATH" \
    -name "$IDENTITY_NAME" \
    -certpbe PBE-SHA1-3DES \
    -keypbe PBE-SHA1-3DES \
    -macalg sha1 \
    -passout "pass:$P12_PASSWORD"

# 密码必须落盘。只打印的话，终端一关这张 p12 就是打不开的废文件 ——
# 比丢了证书还麻烦，因为你会以为自己还有备份。
printf '%s' "$P12_PASSWORD" > "$PASSWORD_PATH"
chmod 600 "$P12_PATH" "$PASSWORD_PATH"

echo "已生成 $P12_PATH"
echo "密码存在 $PASSWORD_PATH"
echo
echo "=== GitHub Secret: MACOS_CERT_PASSWORD ==="
echo "$P12_PASSWORD"
echo
echo "=== GitHub Secret: MACOS_CERT_P12 (base64) ==="
base64 < "$P12_PATH"
echo
echo "两个都加进仓库的 Actions secrets，然后推 tag 即可发版。"
echo "记得把这个目录再备份一份到机器之外（密码管理器之类）。"
