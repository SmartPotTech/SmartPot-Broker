#!/bin/sh
# Genera la CA privada de SmartPot y el certificado TLS del broker.
#   sh scripts/generate-certs.sh <carpeta> <host> [archivo de entropía]
# La CA firma solo el certificado del servidor; ca.key debe guardarse fuera del servidor.
set -eu

OUT="${1:?Uso: generate-certs.sh <carpeta> <host> [entropía]}"
HOST="${2:?Indica el host público, por ejemplo mqtt.smartpot.app}"
ENTROPY="${3:-}"
CA_DAYS="${CA_DAYS:-3650}"
SERVER_DAYS="${SERVER_DAYS:-825}"

RAND=""
if [ -n "$ENTROPY" ]; then
  RAND="-rand $ENTROPY"
fi

mkdir -p "$OUT"
cd "$OUT"

if [ ! -f ca.key ]; then
  # shellcheck disable=SC2086
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 $RAND -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days "$CA_DAYS" \
    -subj "/O=SmartPot Tech/CN=SmartPot MQTT CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.crt
  echo "CA creada: ca.crt (pública) y ca.key (privada)."
else
  echo "Se reutiliza la CA existente."
fi

# shellcheck disable=SC2086
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 $RAND -out server.key
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
echo "Certificado del servidor para $HOST válido por $SERVER_DAYS días."
