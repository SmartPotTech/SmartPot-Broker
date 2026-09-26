#!/bin/sh
set -eu

DYNSEC_FILE="/mosquitto/data/dynamic-security.json"

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

exec "$@"
