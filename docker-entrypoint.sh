#!/bin/sh
set -eu

DYNSEC_FILE="/mosquitto/data/dynamic-security.json"
BASE_CONFIG="/mosquitto/config/mosquitto.conf"
CONFIG="/tmp/mosquitto.conf"
CERTS_DIR="${MQTT_CERTS_DIR:-/etc/mosquitto/certs}"
TLS_MAX_CONNECTIONS="${MQTT_TLS_MAX_CONNECTIONS:-200}"

if [ ! -f "$DYNSEC_FILE" ]; then
  : "${MQTT_ADMIN_USERNAME:?Falta MQTT_ADMIN_USERNAME para inicializar el broker}"
  : "${MQTT_ADMIN_PASSWORD:?Falta MQTT_ADMIN_PASSWORD para inicializar el broker}"
  if [ "${#MQTT_ADMIN_PASSWORD}" -lt 16 ]; then
    echo "MQTT_ADMIN_PASSWORD debe tener al menos 16 caracteres."
    exit 1
  fi
  echo "Inicializando la seguridad dinámica con el usuario $MQTT_ADMIN_USERNAME..."
  mosquitto_ctrl dynsec init "$DYNSEC_FILE" "$MQTT_ADMIN_USERNAME" "$MQTT_ADMIN_PASSWORD" >/dev/null
  chmod 600 "$DYNSEC_FILE"
else
  echo "Seguridad dinámica existente en $DYNSEC_FILE; se conservan usuarios y roles."
fi

cp "$BASE_CONFIG" "$CONFIG"
if [ -r "$CERTS_DIR/ca.crt" ] && [ -r "$CERTS_DIR/server.crt" ] && [ -r "$CERTS_DIR/server.key" ]; then
  cat >> "$CONFIG" <<EOF

# Público: MQTT sobre TLS para las macetas.
listener 8883 0.0.0.0
protocol mqtt
cafile $CERTS_DIR/ca.crt
certfile $CERTS_DIR/server.crt
keyfile $CERTS_DIR/server.key
require_certificate false
tls_version tlsv1.2
max_connections $TLS_MAX_CONNECTIONS
EOF
  echo "Listener TLS habilitado en 8883 con los certificados de $CERTS_DIR."
else
  echo "Sin certificados en $CERTS_DIR: el listener TLS (8883) queda deshabilitado."
fi

if [ "${1:-}" = "mosquitto" ]; then
  exec mosquitto -c "$CONFIG"
fi
exec "$@"
