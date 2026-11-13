#!/usr/bin/env bash
# Renderiza la configuración de EMQX desde la plantilla, siembra la cuenta de servicio y la clave de API,
# limita los hilos del BEAM y añade el listener TLS si hay certificados. Luego cede el control al
# arranque oficial de EMQX (que fija el nombre y la cookie del nodo).
set -euo pipefail

TEMPLATE="/opt/emqx/etc/emqx.conf.template"
CONFIG="/opt/emqx/etc/emqx.conf"
DATA_DIR="/opt/emqx/data/smartpot"
ADMIN_BOOTSTRAP="$DATA_DIR/admin-bootstrap.csv"
APIKEY_BOOTSTRAP="$DATA_DIR/api-key.bootstrap"
CERTS_DIR="${MQTT_CERTS_DIR:-/opt/emqx/etc/certs}"

# --- Configuración y valores por defecto ---
ADMIN_USERNAME="${MQTT_ADMIN_USERNAME:-smartpot-api}"
: "${MQTT_ADMIN_PASSWORD:?Missing MQTT_ADMIN_PASSWORD for the broker service account}"
if [ "${#MQTT_ADMIN_PASSWORD}" -lt 16 ]; then
  echo "MQTT_ADMIN_PASSWORD must be at least 16 characters long." >&2
  exit 1
fi
: "${MQTT_AUTHN_TOKEN:?Missing MQTT_AUTHN_TOKEN: shared secret with the API to authenticate devices}"
AUTHN_URL="${MQTT_AUTHN_URL:-http://api-smartpot:8091/internal/mqtt/authn}"
: "${MQTT_BROKER_API_KEY:?Missing MQTT_BROKER_API_KEY for the EMQX REST API}"
: "${MQTT_BROKER_API_SECRET:?Missing MQTT_BROKER_API_SECRET for the EMQX REST API}"
SCHEDULERS="${MQTT_SCHEDULERS:-2}"
LOG_LEVEL="${MQTT_LOG_LEVEL:-warning}"
TLS_MAX_CONNECTIONS="${MQTT_TLS_MAX_CONNECTIONS:-2000}"
TLS_MAX_CONN_RATE="${MQTT_TLS_MAX_CONN_RATE:-100}"
NODE_COOKIE="${MQTT_NODE_COOKIE:-smartpot-emqx}"
DASHBOARD_PASSWORD="${MQTT_DASHBOARD_PASSWORD:-$(head -c 18 /dev/urandom | base64 | tr -d '/+=')}"

mkdir -p "$DATA_DIR"

# --- Autorización de la cuenta de servicio (la API) ---
# En un volumen nuevo el superusuario de la base interna no basta: authorization.no_match = deny hace que
# EMQX le niegue la suscripción a smartpot/v1/+/telemetry. Esta fuente de archivo le permite publicar y
# suscribirse solo al árbol de SmartPot (incluidas las suscripciones compartidas $share). Los dispositivos
# siguen recibiendo su ACL acotada en la respuesta de /internal/mqtt/authn.
ACL_FILE="/tmp/acl.conf"
printf '{allow, {username, "%s"}, all, ["smartpot/v1/#", "$share/#"]}.\n' "$ADMIN_USERNAME" > "$ACL_FILE"
chmod 644 "$ACL_FILE"

# --- Siembra de la cuenta de servicio (solo en el primer arranque; EMQX conserva la existente) ---
printf 'user_id,password,is_superuser\n%s,%s,true\n' "$ADMIN_USERNAME" "$MQTT_ADMIN_PASSWORD" > "$ADMIN_BOOTSTRAP"
chmod 600 "$ADMIN_BOOTSTRAP"

# --- Clave de la API REST (la usa la API para desconectar sesiones al rotar o borrar) ---
printf '%s:%s:administrator\n' "$MQTT_BROKER_API_KEY" "$MQTT_BROKER_API_SECRET" > "$APIKEY_BOOTSTRAP"
chmod 600 "$APIKEY_BOOTSTRAP"

# --- Hilos del BEAM: +S N:N (ERL_ZFLAGS tiene prioridad sobre los valores por defecto de EMQX) ---
export ERL_ZFLAGS="+S ${SCHEDULERS}:${SCHEDULERS} ${ERL_ZFLAGS:-}"

# --- Listener TLS (8883): solo si hay certificados montados ---
if [ -r "$CERTS_DIR/ca.crt" ] && [ -r "$CERTS_DIR/server.crt" ] && [ -r "$CERTS_DIR/server.key" ]; then
  TLS_BLOCK="listeners.ssl.default {
  bind = \"0.0.0.0:8883\"
  max_connections = ${TLS_MAX_CONNECTIONS}
  max_conn_rate = ${TLS_MAX_CONN_RATE}
  ssl_options {
    cacertfile = \"${CERTS_DIR}/ca.crt\"
    certfile = \"${CERTS_DIR}/server.crt\"
    keyfile = \"${CERTS_DIR}/server.key\"
    verify = verify_none
    fail_if_no_peer_cert = false
    versions = [\"tlsv1.3\", \"tlsv1.2\"]
  }
}"
  echo "TLS listener enabled on 8883 using certificates from $CERTS_DIR."
else
  TLS_BLOCK="listeners.ssl.default { enable = false }"
  echo "No certificates in $CERTS_DIR: TLS listener (8883) disabled."
fi

# --- Render de la configuración (sustitución literal, segura para cualquier valor) ---
content="$(cat "$TEMPLATE")"
content="${content//@AUTHN_URL@/$AUTHN_URL}"
content="${content//@AUTHN_TOKEN@/$MQTT_AUTHN_TOKEN}"
content="${content//@NODE_COOKIE@/$NODE_COOKIE}"
content="${content//@LOG_LEVEL@/$LOG_LEVEL}"
content="${content//@DASHBOARD_PASSWORD@/$DASHBOARD_PASSWORD}"
content="${content//@TLS_LISTENER@/$TLS_BLOCK}"
printf '%s\n' "$content" > "$CONFIG"

echo "EMQX configuration ready (schedulers: $SCHEDULERS, device authentication via $AUTHN_URL)."

# Cede el control al arranque oficial de EMQX.
exec /usr/bin/docker-entrypoint.sh "$@"
