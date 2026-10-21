#!/bin/bash
# Create the self-signed code-signing identity "Insomnia Local Signing" in the
# login keychain, once. Sign source builds with it (scripts/install.sh --sign
# "Insomnia Local Signing") so the designated requirement of the app is
#   identifier "com.kgarg.insomnia" and certificate leaf = H"<cert hash>"
# and stays the same across rebuilds. An ad-hoc build's requirement is its
# cdhash, which changes every build; the keychain item ACL for the hotspot
# password then refuses the new build.
#
# Usage: scripts/make-local-signing-identity.sh [--name CN] [--keychain PATH]
#   Does nothing when the keychain already has a certificate with that
#   common name and its private key (idempotent). No trust settings are
#   added (no add-trusted-cert): codesign signs with an untrusted
#   self-signed identity, and `security find-identity -v` does not list it.
#   The key is imported with codesign allowed to use it without a prompt.
set -euo pipefail

# Fixed tool paths: never taken from PATH.
SECURITY=/usr/bin/security
OPENSSL=/usr/bin/openssl
MKTEMP=/usr/bin/mktemp
RM=/bin/rm

usage() { echo "usage: $0 [--name COMMON_NAME] [--keychain PATH]" >&2; }
NAME="Insomnia Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
while (( $# )); do
  case "$1" in
    --name) [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }; NAME="$2"; shift 2 ;;
    --keychain) [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }; KEYCHAIN="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
case "$NAME" in
  *[!A-Za-z0-9\ ._-]*|"") echo "--name may only contain letters, digits, space, '.', '_' and '-'" >&2; exit 2 ;;
esac
[[ -f "$KEYCHAIN" ]] || { echo "keychain not found: $KEYCHAIN" >&2; exit 1; }

# A certificate with a private key under this name is an identity
# (find-identity without -v also lists untrusted ones).
if "$SECURITY" find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -F -q "\"$NAME\""; then
  echo "identity \"$NAME\" already exists in $KEYCHAIN; nothing to do"
  exit 0
fi

WORK="$("$MKTEMP" -d)"
trap '"$RM" -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# One-time random password. Both LibreSSL (the system openssl) and OpenSSL 3
# write a p12 that `security import` reads when the legacy-compatible
# algorithms are requested; LibreSSL does not know the option, so try it
# first and fall back to the plain form.
P12_PASS="$("$OPENSSL" rand -hex 24)"
export P12_PASS
if ! "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
     -name "$NAME" -passout env:P12_PASS -legacy -out "$WORK/id.p12" 2>/dev/null; then
  "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout env:P12_PASS -out "$WORK/id.p12"
fi

"$SECURITY" import "$WORK/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null
unset P12_PASS

echo "created identity \"$NAME\" in $KEYCHAIN (self-signed, 10 years, no trust settings)"
echo "use it: scripts/install.sh --sign \"$NAME\""
