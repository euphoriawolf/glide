#!/bin/bash
# Create a self-signed code-signing identity for Glide, one time.
# The identity lives in its own keychain file in .signing/, not in the login keychain.
# A stable identity keeps the Accessibility permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR=.signing
KC="$PWD/$DIR/glide.keychain-db"
NAME="Glide Local Signing"

if [ -f "$KC" ]; then
  echo "Signing keychain exists: $KC"
  exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
PASS=$(openssl rand -hex 24)
printf '%s' "$PASS" > "$DIR/password"
chmod 600 "$DIR/password"

# Use the system LibreSSL: its .p12 output imports into the keychain.
SSL=/usr/bin/openssl
cat > "$DIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
$SSL req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -config "$DIR/cert.cnf" 2>/dev/null
$SSL pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
  -name "$NAME" -out "$DIR/identity.p12" -passout pass:"$PASS"
rm "$DIR/key.pem"

# create-keychain adds the new keychain to the search list. Put the old list back after.
OLD_LIST=$(security list-keychains -d user | sed 's/^ *"//; s/"$//')
security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import "$DIR/identity.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
rm "$DIR/identity.p12"
# shellcheck disable=SC2086
security list-keychains -d user -s $OLD_LIST

echo "Created $KC with identity \"$NAME\""
