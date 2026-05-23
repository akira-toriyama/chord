#!/usr/bin/env bash
# setup-signing-cert.sh — create a persistent self-signed identity
# so chord's Accessibility grant survives `swift build` rebuilds.
#
# TCC keys the grant to the code-signing identity. Ad-hoc signing
# (the default for `swift build`) re-signs to a different ad-hoc
# identity every time, which drops the grant on every rebuild. A
# stable self-signed cert keeps the same identity across rebuilds
# and `package.sh` runs.
#
# This mirrors stroke's / facet's identical script.

set -euo pipefail

CN="chord-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" \
    | grep -q "\"$CN\""; then
  echo "Identity '$CN' already exists. Done."
  exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
prompt             = no
x509_extensions    = v3_self

[ req_distinguished_name ]
CN = $CN

[ v3_self ]
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature
extendedKeyUsage       = codeSigning
subjectKeyIdentifier   = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -config "$TMPDIR/openssl.cnf" \
  -keyout "$TMPDIR/$CN.key" \
  -out "$TMPDIR/$CN.crt"

# .p12 bundle so security(1) can import it into the login keychain
# with the private key intact.
openssl pkcs12 -export \
  -inkey "$TMPDIR/$CN.key" -in "$TMPDIR/$CN.crt" \
  -name "$CN" -passout pass: -out "$TMPDIR/$CN.p12"

security import "$TMPDIR/$CN.p12" -k "$KEYCHAIN" -P "" \
  -T /usr/bin/codesign -T /usr/bin/security

# Trust the cert for code signing.
security add-trusted-cert -d -r trustRoot -p codeSign \
  -k "$KEYCHAIN" "$TMPDIR/$CN.crt" 2>/dev/null || true

echo "Created identity '$CN'. Sign with:"
echo "  codesign --force --options runtime --sign $CN <target>"
