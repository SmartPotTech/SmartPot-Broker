# SmartPot-Broker (EMQX)

[![Broker Image CI](https://github.com/SmartPotTech/SmartPot-Broker/actions/workflows/ci.yml/badge.svg)](https://github.com/SmartPotTech/SmartPot-Broker/actions/workflows/ci.yml)
[![Publish Docker Images](https://github.com/SmartPotTech/SmartPot-Broker/actions/workflows/packaging.yml/badge.svg)](https://github.com/SmartPotTech/SmartPot-Broker/actions/workflows/packaging.yml)

[English](#english) | [Español](#español)

---

## English

### Overview

SmartPot-Broker is the **MQTT broker** for SmartPot: the transport layer through which crop telemetry and actuator commands travel. It is built on **EMQX 5.8** (open source) with **TLS 1.2+** over a private CA, anonymous access disabled, and strict per-crop isolation: each device can only publish its own telemetry and only receives its own commands.

It replaces the previous Eclipse Mosquitto broker while keeping the **device contract identical** (same topics, same username and password, same TLS with the CA embedded in the firmware). What changes is the internal operation: instead of provisioning accounts inside the broker via control topics, **the broker delegates authentication to the API**.

[SmartPot-API](https://github.com/SmartPotTech/SmartPot-API) is the center: EMQX only communicates with it. When a device connects, EMQX queries the API over HTTP; the API verifies the crop key against its database and responds with the permission and a crop-scoped ACL. A real crop uses the key on its ESP32 (physical or Wokwi); a virtual one uses it through the simulator. The API does not register or delete anything in the broker: the key lives in the database, so creating, rotating, or deleting a crop takes effect immediately without touching the broker (upon rotation or deletion, the API disconnects active sessions via the EMQX REST API).

### Project Structure

```text
SmartPot-Broker/
├── .github/
│   ├── dependabot.yml          # Base image and GitHub Actions updates
│   └── workflows/
│       ├── ci.yml              # Builds the image and runs the security smoke test
│       ├── packaging.yml       # Publishes the image to GHCR with SBOM and provenance (and Docker Hub when configured)
│       └── deploy.yml          # Triggers deployment on the central SmartPotTech/.github workflow
├── config/
│   └── emqx.conf.template      # Listeners, authentication chain, authorization, and REST API (rendered by entrypoint)
├── scripts/
│   └── generate-certs.sh       # Private CA and broker TLS certificate (the CA is never regenerated)
├── tests/
│   └── smoke.sh                # Authentication, per-device isolation, TLS, and listeners (using an API stub)
├── compose.yaml                # Hardened local broker
├── docker-entrypoint.sh        # Renders config, seeds service account and API key, and configures TLS
├── Dockerfile
└── .env.example
```

### Security Model

| Account                          | Used By                                                            | Permissions                                                                                                                  |
|----------------------------------|--------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------|
| Service (`MQTT_ADMIN_USERNAME`)  | SmartPot-API                                                       | Seeded as a superuser in the internal EMQX database; an explicit ACL file rule also allows `smartpot/v1/#` and `$share/#`   |
| Device                           | One connection per crop: username = crop ID, password = device key | Publish to `smartpot/v1/{own id}/telemetry`, `/commands/ack`, and `/status`; subscribe to `smartpot/v1/{own id}/commands`    |

Device authentication is resolved by the API over HTTP and returns a **per-crop ACL** (`acl` field in the authentication response, EMQX 5.8+): only `smartpot/v1/{id}/...` for the crop itself is allowed and everything else is denied. Thus, a device cannot read or write on behalf of another crop even if it knows its ID, without the broker storing any per-device state. Anything outside the ACL is rejected and disconnects the session (`no_match = deny`, `deny_action = disconnect`).

The entrypoint generates `/tmp/acl.conf` from `MQTT_ADMIN_USERNAME` and registers it as the first authorization source. This covers fresh volumes where `authorization.no_match = deny` would otherwise reject the API's subscription to `smartpot/v1/+/telemetry` or its `$share/...` subscription. The smoke test verifies both filters on a brand-new broker volume and that retained status survives a broker restart, because retained messages are stored on disk in the data volume.

The API also binds every device session to its crop: the MQTT client ID must be `smartpot-<cropId>` for a real device or `smartpot-sim-<cropId>` for the simulator. A different client ID is rejected during authentication, which prevents session takeover with a predictable ID.

### TLS and Connectivity

| Listener                        | Purpose                                                   | Production Exposure                              |
|---------------------------------|-----------------------------------------------------------|--------------------------------------------------|
| `8883` MQTT over TLS (1.2+)     | Real crop devices                                         | Direct at `mqtt.smartpot.app:8883`               |
| `9001` WebSocket (path `/mqtt`) | Web clients                                               | `wss://mqtt.smartpot.app/mqtt` behind Nginx      |
| `1883` MQTT                     | The API and simulator inside the internal Docker network  | Never exposed publicly                           |
| `18083` REST API                | The API, to disconnect sessions upon key rotation/delete  | Never exposed publicly                           |

The TLS listener is enabled only if `ca.crt`, `server.crt`, and `server.key` exist in `/opt/emqx/etc/certs` (mounted read-only). The device verifies the server with `ca.crt`, which is public and distributed with the firmware; the broker does not require a client certificate (`verify = verify_none`), so the device authenticates with username and password.

To generate the CA and server certificate:

```bash
sh scripts/generate-certs.sh certs mqtt.smartpot.app
```

> [!IMPORTANT]
> The CA is **not regenerated** if it already exists: the firmware has it embedded and would stop trusting the broker. The server certificate can be renewed (signed by the same CA). `ca.key` signs certificates and must **not** remain on the server.

### Topics (Contract v1)

| Topic                               | Direction                           | Payload                                                                                                        |
|-------------------------------------|-------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `smartpot/v1/{cropId}/telemetry`    | Device → API                        | `{"temperature":24.5,"humidity":61,"brightness":710,"ph":6.1,"tds":820,"atmosphere":1012.8,"soilMoisture":55}` |
| `smartpot/v1/{cropId}/commands`     | API → Device (QoS 1)                | `{"id":"…","actuator":"WATER_PUMP","action":"ACTIVATE","durationSeconds":30}`                                  |
| `smartpot/v1/{cropId}/commands/ack` | Device → API (QoS 1)                | `{"id":"…","status":"EXECUTED","message":"Pump turned on"}`                                                    |
| `smartpot/v1/{cropId}/status`       | Device (retained, Last Will)        | `online` / `offline`                                                                                           |

### Installation Guide

#### One-Command Deployment

The image is public: `ghcr.io/smartpottech/smartpot-broker`. The full platform starts with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/SmartPotTech/.github/main/docker/demo-beta/compose.yaml | docker compose -f - up -d --wait
```

Open http://localhost:5173 and sign in with `demo@smartpot.app` / `SmartPot2026`. Stop with `docker compose -p smartpot-demo-beta down` (add `-v` to also remove data). See [demo beta](https://github.com/SmartPotTech/.github/tree/main/docker/demo-beta) for details.

#### From Source with Docker Compose

```bash
cp .env.example .env    # set MQTT_ADMIN_PASSWORD, MQTT_AUTHN_TOKEN, and the REST API key
docker compose up -d
```

#### Smoke Test

```bash
docker build -t smartpot-broker:ci .
sh tests/smoke.sh smartpot-broker:ci
```

### Documentation

Component documentation is in [`docs/`](docs/SmartPot_Broker_EMQX_Documentation.md). The [Technical Documentation](https://github.com/SmartPotTech/.github/blob/main/docs/SmartPot_Technical_Documentation.md) details the MQTT contract, per-crop permissions, and production network.

### Industrial Roadmap: MQTT v5, X.509 mTLS, and gRPC ExHook Stream

As part of the **Stack B Maximization Master Plan (demo-beta)**, `SmartPot-Broker` evolves toward an ultra-low-power, hardware-secured cyber-physical architecture:

1. **MQTT v5.0 Protocol & Topic Aliases**: `topic_alias_maximum = 64` reduces full telemetry topic strings to a 2-byte integer identifier after the initial packet.
2. **X.509 mTLS Cryptographic Security**: Mutual TLS authentication based on Ed25519 / ECDSA P-256 client certificates with TLS Session Resumption (< 15 ms) and strict `peer_cert_cn == clientid` ACL rules.
3. **Persistent gRPC ExHook Integration**: Replaces HTTP webhooks with a multiplexed HTTP/2 gRPC channel directly to `SmartPot-API-Go:9090`.

### License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

---

## Español

### Descripción

SmartPot-Broker es el **receptor MQTT** de SmartPot: la pieza por la que viajan la telemetría de los cultivos y los comandos hacia sus actuadores. Es una imagen de **EMQX 5.8** (open source) con **TLS 1.2 o superior** sobre una CA propia, sin acceso anónimo y con aislamiento por cultivo: cada dispositivo solo puede publicar su propia telemetría y solo recibe sus propios comandos.

Reemplaza al broker anterior de Eclipse Mosquitto manteniendo **idéntico el contrato de los dispositivos** (mismos tópicos, mismo usuario y clave, mismo TLS con la CA incrustada en el firmware). Lo que cambia es la operación interna: en vez de aprovisionar cuentas en el broker por tópicos de control, **el broker delega la autenticación en la API**.

[SmartPot-API](https://github.com/SmartPotTech/SmartPot-API) es el centro: EMQX solo habla con ella. Al conectarse un dispositivo, EMQX pregunta a la API por HTTP; la API verifica la clave del cultivo contra su base y responde con el permiso y un ACL acotado a ese cultivo. Un cultivo real usa la clave en su ESP32 (físico o en Wokwi); uno virtual, a través del simulador. La API no registra ni borra nada en el broker: la clave vive en la base, así que crear, rotar o borrar un cultivo tiene efecto inmediato sin tocar al broker (al rotar o borrar, la API corta las sesiones vivas por la API REST de EMQX).

### Estructura del Proyecto

```text
SmartPot-Broker/
├── .github/
│   ├── dependabot.yml          # Actualización de la imagen base y de las Actions
│   └── workflows/
│       ├── ci.yml              # Construye la imagen y corre la prueba de seguridad
│       ├── packaging.yml       # Publica la imagen en GHCR con SBOM y procedencia (y en Docker Hub con credenciales)
│       └── deploy.yml          # Pide el despliegue al workflow central de SmartPotTech/.github
├── config/
│   └── emqx.conf.template      # Listeners, cadena de autenticación, autorización y API REST (el entrypoint la renderiza)
├── scripts/
│   └── generate-certs.sh       # CA privada y certificado TLS del broker (la CA no se regenera)
├── tests/
│   └── smoke.sh                # Autenticación, aislamiento por dispositivo, TLS y listeners (con un stub de la API)
├── compose.yaml                # Broker local endurecido
├── docker-entrypoint.sh        # Renderiza la config, siembra la cuenta de servicio y la clave de API, y añade el TLS
├── Dockerfile
└── .env.example
```

### Modelo de Seguridad

| Cuenta                                | Quién la usa                                                 | Permisos                                                                                                               |
|---------------------------------------|--------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| Servicio (`MQTT_ADMIN_USERNAME`)      | SmartPot-API                                                 | Se siembra como superusuario en la base interna de EMQX; además, una regla ACL de archivo le permite `smartpot/v1/#` y `$share/#` |
| Dispositivo                           | Una conexión por cultivo: usuario = id del cultivo, clave = clave del dispositivo | Publicar en `smartpot/v1/{su id}/telemetry`, `/commands/ack` y `/status`; suscribirse a `smartpot/v1/{su id}/commands` |

La autenticación de los dispositivos la resuelve la API por HTTP y devuelve un **ACL por cultivo** (campo `acl` de la respuesta de autenticación, EMQX 5.8+): se permite solo `smartpot/v1/{id}/...` del propio cultivo y se niega el resto. Así un dispositivo no puede escribir ni leer a nombre de otro cultivo aunque conozca su id, sin que el broker guarde ningún estado por dispositivo. Lo que no coincide con el ACL se rechaza y se corta la conexión (`no_match = deny`, `deny_action = disconnect`).

El entrypoint genera `/tmp/acl.conf` a partir de `MQTT_ADMIN_USERNAME` y lo registra como primera fuente de autorización. Eso cubre los volúmenes nuevos donde `authorization.no_match = deny` rechazaría la suscripción de la API a `smartpot/v1/+/telemetry` o su suscripción `$share/...`. La prueba de humo verifica ambos filtros en un broker recién levantado y que el estado retenido sobrevive a un reinicio del broker, porque los mensajes retenidos se guardan en disco en el volumen de datos.

La API también liga cada sesión de dispositivo a su cultivo: el client ID MQTT debe ser `smartpot-<cropId>` para un dispositivo real o `smartpot-sim-<cropId>` para el simulador. Un client ID distinto se rechaza en la autenticación, lo que impide el takeover de sesión con un id predecible.

### TLS y Conexión

| Listener                               | Uso                                                       | Publicación en producción                        |
|----------------------------------------|-----------------------------------------------------------|--------------------------------------------------|
| `8883` MQTT sobre TLS (1.2 o superior) | Dispositivos de los cultivos reales                       | Directo en `mqtt.smartpot.app:8883`              |
| `9001` WebSocket (ruta `/mqtt`)        | Clientes web                                              | `wss://mqtt.smartpot.app/mqtt` a través de Nginx |
| `1883` MQTT                            | La API y el simulador, dentro de la red interna de Docker | Nunca se publica                                 |
| `18083` API REST                       | La API, para desconectar sesiones al rotar o borrar       | Nunca se publica                                 |

Para generar la CA y el certificado del servidor:

```bash
sh scripts/generate-certs.sh certs mqtt.smartpot.app
```

> [!IMPORTANT]
> La CA **no se regenera** si ya existe: el firmware la lleva incrustada y dejaría de confiar en el broker. El certificado del servidor sí puede renovarse (lo firma la misma CA). `ca.key` firma los certificados y **no** debe quedar en el servidor.

### Tópicos (contrato v1)

| Tópico                              | Sentido                                 | Carga                                                                                                          |
|-------------------------------------|-----------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `smartpot/v1/{cropId}/telemetry`    | Dispositivo → API                       | `{"temperature":24.5,"humidity":61,"brightness":710,"ph":6.1,"tds":820,"atmosphere":1012.8,"soilMoisture":55}` |
| `smartpot/v1/{cropId}/commands`     | API → dispositivo (QoS 1)               | `{"id":"…","actuator":"WATER_PUMP","action":"ACTIVATE","durationSeconds":30}`                                  |
| `smartpot/v1/{cropId}/commands/ack` | Dispositivo → API (QoS 1)               | `{"id":"…","status":"EXECUTED","message":"Pump turned on"}`                                                    |
| `smartpot/v1/{cropId}/status`       | Dispositivo (retenido, última voluntad) | `online` / `offline`                                                                                           |

### Guía de Instalación

#### Despliegue en un comando

```bash
curl -fsSL https://raw.githubusercontent.com/SmartPotTech/.github/main/docker/demo-beta/compose.yaml | docker compose -f - up -d --wait
```

Abre http://localhost:5173 e ingresa con `demo@smartpot.app` / `SmartPot2026`. Se detiene con `docker compose -p smartpot-demo-beta down` (con `-v` borra también los datos). Más detalle en la [demo beta](https://github.com/SmartPotTech/.github/tree/main/docker/demo-beta).

#### Desde el código con Docker Compose

```bash
cp .env.example .env    # define MQTT_ADMIN_PASSWORD, MQTT_AUTHN_TOKEN y la clave de la API REST
docker compose up -d
```

#### Prueba de humo

```bash
docker build -t smartpot-broker:ci .
sh tests/smoke.sh smartpot-broker:ci
```

### Documentación

Su documentación propia está en [`docs/`](docs/SmartPot_Broker_EMQX_Documentation.md). La [documentación técnica](https://github.com/SmartPotTech/.github/blob/main/docs/SmartPot_Technical_Documentation.md) detalla el contrato MQTT, los permisos por cultivo y la red de producción.

### Hoja de Ruta Industrial: MQTT v5, mTLS X.509 y Stream gRPC ExHook

Como parte del **Plan Maestro de Maximización del Stack B (demo-beta)**, `SmartPot-Broker` evoluciona hacia una arquitectura ciberfísica de ultra-bajo consumo y seguridad de hardware:

1. **Protocolo MQTT v5.0 y Topic Aliases**: `topic_alias_maximum = 64` obligatorio, reduciendo los tópicos extensos de telemetría a un identificador entero de 2 bytes tras el paquete inicial.
2. **Seguridad Criptográfica mTLS X.509**: Autenticación mutua en el handshake TLS basada en certificados cliente Ed25519 / ECDSA P-256 con TLS Session Resumption (Session Tickets < 15 ms) y regla ACL criptográfica `peer_cert_cn == clientid`.
3. **Integración gRPC ExHook Persistente**: Sustitución de los webhooks HTTP por un canal gRPC persistente multiplexado sobre HTTP/2 directo hacia `SmartPot-API-Go:9090`.

### Licencia

Este proyecto está bajo la licencia MIT. Consulta el archivo [LICENSE](LICENSE) para más detalles.
