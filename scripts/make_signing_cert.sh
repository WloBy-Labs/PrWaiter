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
# signing-cert.p12 和密码都要留好：每次发版复用同一张证书，身份才是稳定的。

IDENTITY_NAME="${IDENTITY_NAME:-PrWaiter Signing}"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/dist}"
P12_PATH="$OUT_DIR/signing-cert.p12"
P12_PASSWORD="${P12_PASSWORD:-$(openssl rand -base64 18 | tr -d '\n')}"

TEMP_DIR="$(mktemp -d /tmp/pr_waiter_cert.XXXXXX)"
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

mkdir -p "$OUT_DIR"

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

chmod 600 "$P12_PATH"

echo "Created $P12_PATH"
echo
echo "=== GitHub Secret: MACOS_CERT_PASSWORD ==="
echo "$P12_PASSWORD"
echo
echo "=== GitHub Secret: MACOS_CERT_P12 (base64) ==="
base64 < "$P12_PATH"
echo
echo "Add both as repository Actions secrets, then push a tag to release."
echo "Reuse the SAME signing-cert.p12 for every release to keep permissions."
