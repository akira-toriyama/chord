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
# Same approach as facet/stroke — including the specific OpenSSL 3
# .p12 export options security(1) requires.

set -euo pipefail
cd "$(dirname "$0")"

CN="chord-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Idempotency: an untrusted self-signed cert does NOT appear in
# `find-identity -p codesigning` (that lists trusted identities
# only), so a naive guard there never trips and every re-run adds a
# duplicate — which then makes `codesign --sign "$CN"` ambiguous.
# Use `find-certificate` (lists untrusted too) and collapse any
# duplicates down to one.
hashes=$(security find-certificate -a -c "$CN" -Z "$KEYCHAIN" \
  2>/dev/null | awk '/SHA-1 hash:/ { print $3 }' || true)
hash_count=$(printf '%s\n' "$hashes" | grep -c . || true)

if [[ "$hash_count" -ge 1 ]]; then
  if [[ "$hash_count" -gt 1 ]]; then
    echo "found $hash_count duplicate \"$CN\" certs — collapsing to one"
    # Keep the first hash, delete the rest.
    skip=true
    while IFS= read -r h; do
      [[ -z "$h" ]] && continue
      if $skip; then skip=false; continue; fi
      security delete-certificate -Z "$h" "$KEYCHAIN" >/dev/null 2>&1 || true
    done <<<"$hashes"
  fi
  echo "identity already present: $CN"
  echo -n "$CN" > .signing-id
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CN
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

# Legacy PKCS12 (SHA-1 MAC / 3DES) + a password: required for
# Apple's `security` to import OpenSSL 3 output without "MAC
# verification failed". Weak crypto but irrelevant — the .p12 lives
# in a per-run /tmp dir and is removed on exit.
P12PW="chord"
openssl pkcs12 -export -legacy -macalg sha1 \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout "pass:$P12PW" -name "$CN" >/dev/null 2>&1

# -A: usable by any app (so /usr/bin/codesign can use the key
# non-interactively without further prompting).
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PW" -A >/dev/null

echo -n "$CN" > .signing-id
echo "created identity: $CN"
# Self-signed + untrusted: it won't show under `find-identity -p
# codesigning` (that lists trusted identities only). codesign still
# uses it by name.
security find-certificate -c "$CN" -Z "$KEYCHAIN" 2>/dev/null \
  | grep 'SHA-1 hash' || true
echo "next: ./package.sh && ./scripts/install-launchagent.sh"
