#!/bin/sh
# Genera la CA privada de SmartPot y el certificado TLS del broker.
#   sh scripts/generate-certs.sh <carpeta> <host> [archivo de entropía]
# Con CLIENT_NAME definido también firma un certificado de cliente (client.key, client.csr, client.crt)
# para dispositivos que quieran TLS mutuo; el broker no lo exige (verify_none).
# ca.key debe guardarse fuera del servidor. Reutiliza la CA existente si ya está en la carpeta:
# NO regeneres la CA, porque el firmware ya la lleva incrustada y dejaría de confiar en el broker.
set -eu

OUT="${1:?Usage: generate-certs.sh <dir> <host> [entropy]}"
HOST="${2:?Specify the public host, e.g. mqtt.smartpot.app}"
ENTROPY="${3:-}"
CA_DAYS="${CA_DAYS:-3650}"
SERVER_DAYS="${SERVER_DAYS:-825}"
CLIENT_NAME="${CLIENT_NAME:-}"

RAND=""
if [ -n "$ENTROPY" ]; then
  RAND="-rand $ENTROPY"
fi

mkdir -p "$OUT"
cd "$OUT"

if [ ! -f ca.key ]; then
  # shellcheck disable=SC2086
  openssl genrsa $RAND -out ca.key 4096
  openssl req -x509 -new -key ca.key -sha256 -days "$CA_DAYS" \
    -subj "/O=SmartPot Tech/CN=SmartPot MQTT CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.crt
  echo "CA created: ca.crt (public) and ca.key (private)."
else
  echo "Reusing existing CA."
fi

# shellcheck disable=SC2086
openssl genrsa $RAND -out server.key 2048
openssl req -new -key server.key -subj "/O=SmartPot Tech/CN=$HOST" -out server.csr
cat > server.ext <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$HOST,DNS:localhost,DNS:broker-smartpot,IP:127.0.0.1
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAserial ca.srl -CAcreateserial \
  -sha256 -days "$SERVER_DAYS" -extfile server.ext -out server.crt
rm -f server.ext
chmod 600 ca.key server.key
openssl verify -CAfile ca.crt server.crt
echo "Server certificate for $HOST valid for $SERVER_DAYS days."

if [ -n "$CLIENT_NAME" ]; then
  # shellcheck disable=SC2086
  openssl genrsa $RAND -out client.key 2048
  openssl req -new -key client.key -subj "/O=SmartPot Tech/CN=$CLIENT_NAME" -out client.csr
  cat > client.ext <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF
  openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAserial ca.srl \
    -sha256 -days "$SERVER_DAYS" -extfile client.ext -out client.crt
  rm -f client.ext
  chmod 600 client.key
  openssl verify -CAfile ca.crt client.crt
  echo "Client certificate for $CLIENT_NAME valid for $SERVER_DAYS days."
fi
