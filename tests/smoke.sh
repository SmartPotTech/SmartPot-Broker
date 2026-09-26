#!/bin/sh
# Prueba de humo: arranca la imagen endurecida y valida autenticación y aislamiento por dispositivo.
set -eu

IMAGE="${1:-smartpot-broker:ci}"
NAME="smartpot-broker-smoke"
ADMIN="smartpot-api"
ADMIN_PASS="smoke-admin-password-123"
DEVICE="6718f0a1b2c3d4e5f6a7b8c9"
OTHER="6718f0a1b2c3d4e5f6a7b8d0"
DEVICE_PASS="smoke-device-key-123"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --name "$NAME" \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -e MQTT_ADMIN_USERNAME="$ADMIN" -e MQTT_ADMIN_PASSWORD="$ADMIN_PASS" \
  -v smartpot-broker-smoke-data:/mosquitto/data \
  "$IMAGE" >/dev/null

for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME")" = "healthy" ] && break
  sleep 1
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME")" = "healthy" ] || { docker logs "$NAME"; exit 1; }

run() { docker exec "$NAME" sh -c "$1"; }
ctrl="mosquitto_ctrl -h 127.0.0.1 -u $ADMIN -P $ADMIN_PASS dynsec"

run "$ctrl createRole device >/dev/null
$ctrl addRoleACL device publishClientSend 'smartpot/v1/%u/telemetry' allow 5 >/dev/null
$ctrl addRoleACL device subscribePattern 'smartpot/v1/%u/commands' allow 5 >/dev/null
$ctrl addRoleACL admin publishClientSend 'smartpot/#' allow 5 >/dev/null
$ctrl addRoleACL admin subscribePattern 'smartpot/#' allow 5 >/dev/null
for id in $DEVICE $OTHER; do $ctrl createClient \$id -p $DEVICE_PASS >/dev/null; $ctrl addClientRole \$id device >/dev/null; done" 2>/dev/null

run "mosquitto_sub -h 127.0.0.1 -u $ADMIN -P $ADMIN_PASS -t 'smartpot/#' -v -W 4 > /tmp/api.log 2>&1 &
mosquitto_sub -h 127.0.0.1 -u $DEVICE -P $DEVICE_PASS -t 'smartpot/v1/$DEVICE/commands' -v -W 4 > /tmp/device.log 2>&1 &
sleep 1
mosquitto_pub -h 127.0.0.1 -u $DEVICE -P $DEVICE_PASS -t 'smartpot/v1/$DEVICE/telemetry' -m own
mosquitto_pub -h 127.0.0.1 -u $DEVICE -P $DEVICE_PASS -t 'smartpot/v1/$OTHER/telemetry' -m foreign
mosquitto_pub -h 127.0.0.1 -u $ADMIN -P $ADMIN_PASS -t 'smartpot/v1/$DEVICE/commands' -m command
sleep 4"

api_log="$(run 'cat /tmp/api.log')"
device_log="$(run 'cat /tmp/device.log')"
fail=0
check() { if eval "$2"; then echo "OK   $1"; else echo "FAIL $1"; fail=1; fi; }

check "la API recibe la telemetría propia del dispositivo" 'echo "$api_log" | grep -q "telemetry own"'
check "el broker descarta telemetría a nombre de otro cultivo" '! echo "$api_log" | grep -q foreign'
check "el dispositivo recibe sus comandos" 'echo "$device_log" | grep -q "commands command"'
check "se rechaza una clave incorrecta" "! docker exec $NAME mosquitto_pub -h 127.0.0.1 -u $DEVICE -P wrong -t x -m y 2>/dev/null"
check "se rechaza la conexión anónima" "! docker exec $NAME mosquitto_pub -h 127.0.0.1 -t x -m y 2>/dev/null"
check "el listener WebSocket está abierto" "docker exec $NAME nc -z 127.0.0.1 9001"
check "el dispositivo no puede suscribirse a comandos ajenos" "docker exec $NAME mosquitto_sub -h 127.0.0.1 -u $DEVICE -P $DEVICE_PASS -t 'smartpot/v1/$OTHER/commands' -C 1 -W 2 2>&1 | grep -q denied"

docker rm -f "$NAME" >/dev/null
docker volume rm smartpot-broker-smoke-data >/dev/null
exit "$fail"
