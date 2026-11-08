#!/bin/zsh
# Creates a stable, self-signed code-signing identity in a project-local keychain
# (~/Library/Application Support/LidFold/lidfold.keychain-db) — your login keychain is not touched.
# Why: macOS ties the Screen Recording permission to the app's signature. Ad-hoc signatures
# change on every build, so the permission would be lost after each rebuild.
set -euo pipefail
cd "${0:A:h}/.."
DIR="$HOME/Library/Application Support/LidFold"; KC="$DIR/lidfold.keychain-db"; PASS=lidfold   # outside the project
[[ -f "$KC" ]] && { echo "Identity already exists: $KC"; exit 0; }
mkdir -p "$DIR"; cd "$DIR"
cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = LidFold Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem -config cert.cnf 2>/dev/null
openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:$PASS -name "LidFold Local Signing" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null
security create-keychain -p $PASS "$KC"
security set-keychain-settings "$KC"            # no auto-lock
security unlock-keychain -p $PASS "$KC"
security import id.p12 -k "$KC" -P $PASS -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k $PASS "$KC" >/dev/null
rm -f key.pem id.p12 cert.cnf
echo "Created signing identity in $KC"
