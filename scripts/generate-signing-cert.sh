#!/usr/bin/env bash
#
# Generate a STABLE self-signed code-signing certificate for Clipth and
# install it into your login keychain so every local build is signed with the
# same identity.
#
# Why this exists
# ---------------
# macOS records the Accessibility (and other TCC) grant against the app's
# code-signing *designated requirement*. An ad-hoc signed app has no stable
# requirement — its requirement is the binary's cdhash, which changes on every
# rebuild and every release. The grant is then silently invalidated even though
# the toggle in System Settings still looks enabled, and the app re-prompts
# ("Clipth wants to control this computer using accessibility features").
#
# Signing with a fixed certificate gives the bundle a stable requirement
# (identifier + this cert's leaf hash), so the grant survives rebuilds and
# updates. This is the free alternative to a paid Developer ID + notarization;
# the only thing it does NOT remove is the first-launch Gatekeeper warning.
#
# Run this ONCE. Re-running mints a *different* certificate (different leaf
# hash) which changes the requirement and re-breaks the saved grant, so the
# script refuses unless you pass --force (i.e. you intend to rotate the cert
# and will re-grant + update the GitHub secrets).
set -euo pipefail

CERT_NAME="Clipth Self-Signed"      # MUST match CODE_SIGN_IDENTITY in the Xcode project
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OUT_DIR="${TMPDIR:-/tmp}/clipth-signing"
P12_PATH="$OUT_DIR/clipth-signing.p12"

force=0
[ "${1:-}" = "--force" ] && force=1

if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
  if [ "$force" -ne 1 ]; then
    cat >&2 <<EOF
An identity named "$CERT_NAME" already exists in your keychain.

Re-creating it would change the code-signing designated requirement and break
the saved Accessibility grant for everyone. If you really mean to rotate the
certificate, re-run with --force, then re-grant Accessibility locally and
update the GitHub secrets.
EOF
    exit 1
  fi
fi

mkdir -p "$OUT_DIR"
KEY_PEM="$OUT_DIR/key.pem"
CERT_PEM="$OUT_DIR/cert.pem"
CONF="$OUT_DIR/openssl.cnf"

# An OpenSSL config (rather than -addext) keeps this working on both OpenSSL
# and the LibreSSL that ships as /usr/bin/openssl on macOS. The codeSigning EKU
# is what makes `codesign` accept the cert; 100-year validity avoids a future
# expiry forcing a cert rotation (which would break the grant).
cat > "$CONF" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no

[ dn ]
CN = $CERT_NAME

[ v3_codesign ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$KEY_PEM" -out "$CERT_PEM" \
  -days 36500 -config "$CONF" -extensions v3_codesign

P12_PASSWORD="$(openssl rand -base64 24)"

# OpenSSL 3.x exports PKCS#12 with AES-256-CBC + a SHA-256 MAC by default, which
# Apple's Security framework (`security import` below) cannot read — it fails
# with "MAC verification failed during PKCS12 import (wrong password?)" even
# though the password is correct. The -legacy flag falls back to the SHA1/3DES
# algorithms macOS understands. LibreSSL (the /usr/bin/openssl that ships with
# macOS) is already legacy and doesn't know the flag, so only add it when the
# openssl on PATH advertises it (i.e. you're using Homebrew's OpenSSL 3.x).
pkcs12_legacy=()
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
  pkcs12_legacy=(-legacy)
fi
openssl pkcs12 -export "${pkcs12_legacy[@]}" \
  -inkey "$KEY_PEM" -in "$CERT_PEM" \
  -name "$CERT_NAME" \
  -out "$P12_PATH" \
  -passout "pass:$P12_PASSWORD"

# Import the identity (cert + private key) and pre-authorise the signing tools.
security import "$P12_PATH" -k "$LOGIN_KEYCHAIN" -P "$P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security

# Let codesign use the key without a GUI prompt on every build. This needs your
# macOS login password; it is only passed to the local `security` command and
# is neither stored nor transmitted. If you skip it, the build still works — you
# just get a one-time "Always Allow" dialog on the first build.
echo
printf 'macOS login password (for codesign keychain access, blank to skip): '
read -rs LOGIN_PW
echo
if [ -n "$LOGIN_PW" ]; then
  if security set-key-partition-list -S apple-tool:,apple:,codesign: \
       -s -k "$LOGIN_PW" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    echo "✅ codesign authorised to use the key without prompting."
  else
    echo "⚠️  Could not set the key partition list (wrong password?)."
    echo "    Builds still work; just click 'Always Allow' on the first prompt."
  fi
else
  echo "Skipped — click 'Always Allow' on the first build prompt."
fi
unset LOGIN_PW

rm -f "$KEY_PEM" "$CERT_PEM" "$CONF"

cat <<EOF

────────────────────────────────────────────────────────────────────────────
✅ Installed code-signing identity: "$CERT_NAME"
   Local Debug/Release builds are now signed with it automatically.

GitHub Actions release secrets (so CI signs releases with the SAME identity):

  SIGNING_CERT_PASSWORD
$(printf '    %s\n' "$P12_PASSWORD")
  SIGNING_CERT_P12_BASE64
$(base64 < "$P12_PATH" | sed 's/^/    /')

Set them from this machine with the GitHub CLI:

  printf %s '$P12_PASSWORD' | gh secret set SIGNING_CERT_PASSWORD
  base64 < '$P12_PATH' | gh secret set SIGNING_CERT_P12_BASE64

The .p12 is at: $P12_PATH
Keep it and the password safe — reusing the SAME certificate is exactly what
keeps the Accessibility grant stable across releases. Delete it afterwards if
you prefer; the identity already lives in your login keychain.
────────────────────────────────────────────────────────────────────────────
EOF
