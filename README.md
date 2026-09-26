# SmartPot-Broker (MQTT)

## Estado del Proyecto

[![Broker Image CI](https://github.com/SmartPotTech/SmartPot-Broker/actions/workflows/ci.yml/badge.svg)](https://github.com/SmartPotTech/SmartPot-Broker/actions/workflows/ci.yml)
[![Publish Package to GHCR](https://github.com/SmartPotTech/SmartPot-Broker/actions/workflows/packaging.yml/badge.svg)](https://github.com/SmartPotTech/SmartPot-Broker/actions/workflows/packaging.yml)

## Descripción

SmartPot-Broker es el **receptor MQTT** de SmartPot: la pieza por la que viajan la telemetría de las macetas y los comandos hacia sus actuadores. Es una imagen de **Eclipse Mosquitto 2.1** con **TLS 1.2** sobre una CA propia, el plugin de **seguridad dinámica**, sin acceso anónimo y con aislamiento por dispositivo: cada maceta solo puede publicar su propia telemetría y solo recibe sus propios comandos.

[SmartPot-API](https://github.com/SmartPotTech/SmartPot-API) es la única cuenta administradora: al crear un cultivo registra en el broker las credenciales de su dispositivo, y al borrarlo las elimina.

## Estructura del Proyecto

```text
SmartPot-Broker/
├── .github/
│   ├── dependabot.yml          # Actualización de la imagen base y de las Actions
│   └── workflows/
│       ├── ci.yml              # Construye la imagen y corre la prueba de seguridad
│       ├── packaging.yml       # Publica la imagen en GHCR (con SBOM y provenance)
│       └── deploy.yml          # Despliega la app completa tras publicar
├── config/
│   └── mosquitto.conf          # Listeners interno (1883) y WebSocket (9001), sesiones y logs
├── scripts/
│   └── generate-certs.sh       # CA privada y certificado TLS del broker
├── tests/
│   └── smoke.sh                # Autenticación, ACL por dispositivo, TLS y listeners
├── compose.yaml                # Broker local endurecido
├── docker-entrypoint.sh        # Inicializa la seguridad dinámica y agrega el listener TLS si hay certificados
├── Dockerfile
└── .env.example
```

## Modelo de Seguridad

| Cuenta | Quién la usa | Permisos |
| --- | --- | --- |
| Administrador (`MQTT_ADMIN_USERNAME`) | SmartPot-API | Control de la seguridad dinámica y lectura/escritura en `smartpot/#` |
| Rol `device` | Una cuenta por cultivo: usuario = id del cultivo, clave = clave del dispositivo | Publicar en `smartpot/v1/{su id}/telemetry`, `/commands/ack` y `/status`; suscribirse a `smartpot/v1/{su id}/commands` |

Las ACL del rol `device` usan el patrón `%u` (el usuario conectado), así que un dispositivo no puede escribir ni leer a nombre de otro cultivo aunque conozca su id. La API crea el rol al arrancar; el broker solo crea el administrador.

## TLS y Conexión

| Listener | Uso | Publicación en producción |
| --- | --- | --- |
| `8883` MQTT sobre TLS 1.2 | Macetas | Directo en `mqtt.smartpot.app:8883` |
| `9001` WebSocket | Clientes web | `wss://mqtt.smartpot.app/mqtt` a través de Nginx |
| `1883` MQTT | Solo la API, dentro de la red interna de Docker | Nunca se publica |

El listener TLS se habilita solo si existen `ca.crt`, `server.crt` y `server.key` en `/etc/mosquitto/certs` (se monta de solo lectura). La maceta verifica el servidor con `ca.crt`, que es público y se distribuye con el firmware; `require_certificate` está en `false`, así que el dispositivo se autentica con usuario y clave, no con certificado de cliente.

Reglas de conexión: un client id vacío se rechaza (`allow_zero_length_clientid false`), las sesiones persistentes expiran a la hora de desconectarse y cada listener limita sus conexiones simultáneas (`MQTT_TLS_MAX_CONNECTIONS`, 200 por defecto).

Para generar la CA y el certificado del servidor:

```bash
sh scripts/generate-certs.sh certs mqtt.smartpot.app
```

`ca.key` firma los certificados y **no** debe quedar en el servidor. Si se pasa un tercer argumento con un archivo de entropía, OpenSSL lo mezcla con su generador al crear las llaves.

## Tópicos (contrato v1)

| Tópico | Sentido | Carga |
| --- | --- | --- |
| `smartpot/v1/{cropId}/telemetry` | Dispositivo → API | `{"temperature":24.5,"humidity":61,"brightness":710,"ph":6.1,"tds":820,"atmosphere":1012.8,"soilMoisture":55}` |
| `smartpot/v1/{cropId}/commands` | API → dispositivo (QoS 1) | `{"id":"…","actuator":"WATER_PUMP","action":"ACTIVATE","durationSeconds":30}` |
| `smartpot/v1/{cropId}/commands/ack` | Dispositivo → API (QoS 1) | `{"id":"…","status":"EXECUTED","message":"Bomba encendida"}` |
| `smartpot/v1/{cropId}/status` | Dispositivo (retenido, última voluntad) | `online` / `offline` |

## Guía de Instalación

### Requisitos Previos

- Docker (Docker Desktop o Docker Engine con Compose v2)

### Ejecución con Docker Compose

```bash
git clone https://github.com/SmartPotTech/SmartPot-Broker.git
cd SmartPot-Broker
cp .env.example .env    # define MQTT_ADMIN_PASSWORD (mínimo 16 caracteres)
docker compose up -d
```

| Puerto | Protocolo | Publicación |
| --- | --- | --- |
| 1883 | MQTT | Solo `127.0.0.1` |
| 8883 | MQTT sobre TLS | Solo `127.0.0.1` en local; con los certificados de `./certs` |
| 9001 | MQTT sobre WebSocket | Solo `127.0.0.1` |

> [!IMPORTANT]
> `MQTT_ADMIN_PASSWORD` solo se aplica cuando el volumen está vacío. Para cambiarla en un broker existente hay que usar `mosquitto_ctrl dynsec setClientPassword` o recrear el volumen (los dispositivos se vuelven a aprovisionar desde la API).

### Prueba de humo

```bash
docker build -t smartpot-broker:ci .
sh tests/smoke.sh smartpot-broker:ci
```

Genera una CA desechable y verifica que la telemetría propia llega a la API, que el broker descarta publicaciones y suscripciones a nombre de otro cultivo, que rechaza claves incorrectas, ids vacíos y conexiones anónimas, y que el listener TLS acepta solo credenciales válidas.

## Imagen publicada

```bash
docker pull ghcr.io/smartpottech/smartpot-broker:latest
```

La imagen corre como el usuario `1883`, admite sistema de archivos de solo lectura (con `tmpfs` en `/tmp` y un volumen en `/mosquitto/data`) y trae un `HEALTHCHECK` sobre el puerto MQTT.

## Licencia

Este proyecto está bajo la licencia MIT. Consulta el archivo [LICENSE](LICENSE) para más detalles.
