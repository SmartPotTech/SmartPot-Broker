# SmartPot-Broker (MQTT)

## Estado del Proyecto

[![Broker Image CI](https://github.com/SmartPotTech/SmartPot-Broker/actions/workflows/ci.yml/badge.svg)](https://github.com/SmartPotTech/SmartPot-Broker/actions/workflows/ci.yml)
[![Publish Package to GHCR](https://github.com/SmartPotTech/SmartPot-Broker/actions/workflows/packaging.yml/badge.svg)](https://github.com/SmartPotTech/SmartPot-Broker/actions/workflows/packaging.yml)

## Descripción

SmartPot-Broker es el **receptor MQTT** de SmartPot: la pieza por la que viajan la telemetría de las macetas y los comandos hacia sus actuadores. Es una imagen de **Eclipse Mosquitto 2.1** con el plugin de **seguridad dinámica**, sin acceso anónimo y con aislamiento por dispositivo: cada maceta solo puede publicar su propia telemetría y solo recibe sus propios comandos.

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
│   └── mosquitto.conf          # Listeners MQTT (1883) y WebSocket (9001), persistencia y logs
├── tests/
│   └── smoke.sh                # Autenticación, ACL por dispositivo y listeners
├── compose.yaml                # Broker local endurecido
├── docker-entrypoint.sh        # Inicializa la seguridad dinámica en el primer arranque
├── Dockerfile
└── .env.example
```

## Modelo de Seguridad

| Cuenta | Quién la usa | Permisos |
| --- | --- | --- |
| Administrador (`MQTT_ADMIN_USERNAME`) | SmartPot-API | Control de la seguridad dinámica y lectura/escritura en `smartpot/#` |
| Rol `device` | Una cuenta por cultivo: usuario = id del cultivo, clave = clave del dispositivo | Publicar en `smartpot/v1/{su id}/telemetry`, `/commands/ack` y `/status`; suscribirse a `smartpot/v1/{su id}/commands` |

Las ACL del rol `device` usan el patrón `%u` (el usuario conectado), así que un dispositivo no puede escribir ni leer a nombre de otro cultivo aunque conozca su id. La API crea el rol al arrancar; el broker solo crea el administrador.

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
| 1883 | MQTT | Solo `127.0.0.1`; en producción Nginx lo expone como MQTT sobre TLS en `8883` |
| 9001 | MQTT sobre WebSocket | Solo `127.0.0.1`; en producción Nginx lo expone como `wss://…/mqtt` |

> [!IMPORTANT]
> `MQTT_ADMIN_PASSWORD` solo se aplica cuando el volumen está vacío. Para cambiarla en un broker existente hay que usar `mosquitto_ctrl dynsec setClientPassword` o recrear el volumen (los dispositivos se vuelven a aprovisionar desde la API).

### Prueba de humo

```bash
docker build -t smartpot-broker:ci .
sh tests/smoke.sh smartpot-broker:ci
```

Verifica que la telemetría propia llega a la API, que el broker descarta publicaciones y suscripciones a nombre de otro cultivo, y que rechaza claves incorrectas y conexiones anónimas.

## Imagen publicada

```bash
docker pull ghcr.io/smartpottech/smartpot-broker:latest
```

La imagen corre como el usuario `1883`, admite sistema de archivos de solo lectura (con `tmpfs` en `/tmp` y un volumen en `/mosquitto/data`) y trae un `HEALTHCHECK` sobre el puerto MQTT.

## Licencia

Este proyecto está bajo la licencia MIT. Consulta el archivo [LICENSE](LICENSE) para más detalles.
