#!/bin/zsh
set -euo pipefail

APP_NAME="PrWaiter"
SIGNING_DIR="${SIGNING_DIR:-$HOME/Library/Application Support/$APP_NAME/signing}"
DEFAULT_LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
KEYCHAIN_PATH="${KEYCHAIN_PATH:-$DEFAULT_LOGIN_KEYCHAIN}"
ENV_PATH="${ENV_PATH:-$SIGNING_DIR/signing.env}"
IDENTITY_NAME="${IDENTITY_NAME:-$APP_NAME Local Signing}"
KEYCHAIN_PASSWORD_PATH="$SIGNING_DIR/keychain_password"
PKCS12_PASSWORD_PATH="$SIGNING_DIR/p12_password"
TEMP_DIR="$(mktemp -d /tmp/pr_waiter_signing.XXXXXX)"
LEGACY_KEYCHAIN_PATH="$HOME/Library/Keychains/PrWaiter-Signing.keychain-db"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

identity_hash_for_keychain() {
    security find-identity -v -p codesigning "$1" 2>/dev/null \
        | awk -v identity_name="$IDENTITY_NAME" '$0 ~ "\"" identity_name "\"" { print $2; exit }'
}

if [[ -f "$KEYCHAIN_PASSWORD_PATH" ]]; then
    KEYCHAIN_PASSWORD="$(<"$KEYCHAIN_PASSWORD_PATH")"
else
    KEYCHAIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
    printf '%s' "$KEYCHAIN_PASSWORD" > "$KEYCHAIN_PASSWORD_PATH"
    chmod 600 "$KEYCHAIN_PASSWORD_PATH"
fi

if [[ -f "$PKCS12_PASSWORD_PATH" ]]; then
    PKCS12_PASSWORD="$(<"$PKCS12_PASSWORD_PATH")"
else
    PKCS12_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
    printf '%s' "$PKCS12_PASSWORD" > "$PKCS12_PASSWORD_PATH"
    chmod 600 "$PKCS12_PASSWORD_PATH"
fi

if [[ "$KEYCHAIN_PATH" != "$DEFAULT_LOGIN_KEYCHAIN" ]]; then
    if [[ ! -f "$KEYCHAIN_PATH" ]]; then
        security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
        security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
    fi

    existing_keychains=("${(@f)$(security list-keychains -d user | sed 's/^[[:space:]]*//; s/^"//; s/"$//')}")
    if [[ ${existing_keychains[(Ie)$KEYCHAIN_PATH]} -eq 0 ]]; then
        security list-keychains -d user -s "$KEYCHAIN_PATH" "${existing_keychains[@]}"
    fi

    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
fi

if [[ -z "$(identity_hash_for_keychain "$KEYCHAIN_PATH")" ]]; then
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
        -new \
        -newkey rsa:2048 \
        -x509 \
        -sha256 \
        -days 3650 \
        -nodes \
        -config "$TEMP_DIR/openssl.cnf" \
        -keyout "$TEMP_DIR/key.pem" \
        -out "$TEMP_DIR/cert.pem"

    pkcs12_legacy_args=()
    if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
        pkcs12_legacy_args=(-legacy)
    fi

    openssl pkcs12 \
        -export \
        "${pkcs12_legacy_args[@]}" \
        -inkey "$TEMP_DIR/key.pem" \
        -in "$TEMP_DIR/cert.pem" \
        -out "$TEMP_DIR/identity.p12" \
        -name "$IDENTITY_NAME" \
        -certpbe PBE-SHA1-3DES \
        -keypbe PBE-SHA1-3DES \
        -macalg sha1 \
        -passout "pass:$PKCS12_PASSWORD"

    security import "$TEMP_DIR/identity.p12" \
        -k "$KEYCHAIN_PATH" \
        -P "$PKCS12_PASSWORD" \
        -T /usr/bin/codesign \
        -T /usr/bin/security

    security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN_PATH" "$TEMP_DIR/cert.pem"

    if [[ "$KEYCHAIN_PATH" != "$DEFAULT_LOGIN_KEYCHAIN" ]]; then
        security set-key-partition-list \
            -S apple-tool:,apple:,codesign: \
            -s \
            -k "$KEYCHAIN_PASSWORD" \
            "$KEYCHAIN_PATH"
    fi
fi

IDENTITY_HASH="$(identity_hash_for_keychain "$KEYCHAIN_PATH")"

if [[ -z "$IDENTITY_HASH" ]]; then
    echo "Failed to locate a usable codesigning identity named '$IDENTITY_NAME' in '$KEYCHAIN_PATH'." >&2
    echo "The certificate may exist, but macOS did not register it as a code-signing identity." >&2
    exit 1
fi

cat > "$ENV_PATH" <<EOF
export CODESIGN_IDENTITY='$IDENTITY_HASH'
export CODESIGN_IDENTITY_NAME='$IDENTITY_NAME'
export CODESIGN_KEYCHAIN='$KEYCHAIN_PATH'
EOF

if [[ "$KEYCHAIN_PATH" != "$DEFAULT_LOGIN_KEYCHAIN" ]]; then
    printf "export CODESIGN_KEYCHAIN_PASSWORD='%s'\n" "$KEYCHAIN_PASSWORD" >> "$ENV_PATH"
fi
chmod 600 "$ENV_PATH"

echo "Created or reused stable signing identity:"
echo "  Identity: $IDENTITY_NAME"
echo "  Fingerprint: $IDENTITY_HASH"
echo "  Keychain: $KEYCHAIN_PATH"
echo "  Env file: $ENV_PATH"
echo
if [[ -f "$LEGACY_KEYCHAIN_PATH" && "$KEYCHAIN_PATH" != "$LEGACY_KEYCHAIN_PATH" ]]; then
    echo "Detected legacy keychain at:"
    echo "  $LEGACY_KEYCHAIN_PATH"
    echo "package_app.sh will ignore duplicate cert names by signing with the exact fingerprint above."
    echo
fi
echo "package_app.sh will use this identity automatically on future builds."
