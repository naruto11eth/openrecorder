#!/bin/bash
# Create a stable self-signed code-signing identity so macOS TCC permissions
# (Screen Recording / Microphone) persist across rebuilds. Ad-hoc signing
# changes the code hash every build, forcing a permission re-grant each time;
# a fixed cert keeps the designated requirement stable.
#
# Run once. Safe to re-run (skips if the identity already exists).
set -euo pipefail

CERT_NAME="OpenRecorder Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Signing identity '$CERT_NAME' already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = OpenRecorder Dev
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cfg" 2>/dev/null

# Legacy PBE + SHA1 MAC: OpenSSL 3.x defaults are not importable by macOS `security`.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
    -passout pass:openrecorder -name "$CERT_NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db \
    -P openrecorder -T /usr/bin/codesign -A

echo "Created signing identity '$CERT_NAME'. Re-run ./make-app.sh to use it."
