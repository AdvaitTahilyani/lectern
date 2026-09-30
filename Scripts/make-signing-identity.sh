#!/bin/zsh
# Creates a self-signed "Lectern Local Signing" code-signing identity (10 years) in the login
# keychain, usable only by codesign. Builds signed with it keep a stable identity, so macOS
# permissions persist across rebuilds. It is only meaningful on this Mac.
set -euo pipefail
if security find-certificate -c "Lectern Local Signing" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  echo "Lectern Local Signing already exists."; exit 0
fi
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
cat > "$dir/cert.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Lectern Local Signing
O = Lectern (local)
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
pass=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/key.pem" -out "$dir/cert.pem" -days 3650 -config "$dir/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "Lectern Local Signing" -out "$dir/cert.p12" -passout "pass:$pass"
security import "$dir/cert.p12" -k ~/Library/Keychains/login.keychain-db -P "$pass" -T /usr/bin/codesign
echo "Created Lectern Local Signing."
