# SmartPot-Broker-EMQX — Technical Documentation / Documentación técnica

[English](#english) | [Español](#español)

---

# English

## 1. Purpose

The broker is the single point of contact between devices (real ESP32 units or the simulator) and the platform. It transports crop telemetry toward the API and API commands toward actuators. This version runs on **EMQX 5.8** and replaces Eclipse Mosquitto without altering the device contract.

## 2. What Changes Compared to Mosquitto

| Aspect                | Mosquitto (previous)                                                                  | EMQX (current)                                                                                 |
|-----------------------|---------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| Device contract       | username = crop ID, device key, TLS with CA, `smartpot/v1/...` topics                 | **Identical** (no firmware or simulator changes)                                               |
| Provisioning          | The API created/deleted accounts and roles via *dynamic security* control topics      | The API does **not** register accounts: the key lives in its DB and EMQX queries it on connect |
| Device authentication | Password stored inside the broker                                                     | HTTP call to the API, which verifies the key and returns the permission + crop ACL             |
| Authorization         | `device` role with `%u` ACL created by the API                                        | Per-crop ACL attached in the authentication response; `no_match = deny`                        |
| API account           | *Dynamic security* admin client                                                       | Superuser seeded into the internal EMQX database                                               |
| Key rotation/deletion | `disableClient`/`enableClient` via control topic                                      | The API disconnects active sessions via the EMQX REST API                                      |

Result: less state and less coupling. The broker stores no device accounts; creating, rotating, or deleting a crop takes effect immediately without synchronizing anything with the broker.

## 3. Authentication and Authorization

### 3.1 Authentication Chain

1. **EMQX Built-in Database** (`built_in_database`): contains a single account, the API service account (`MQTT_ADMIN_USERNAME`), seeded as a **superuser** from a bootstrap file on first boot. For any other user, the database returns `ignore` and the chain continues.
2. **HTTP to the API** (`http`): for devices. EMQX sends a `POST` request to the internal API endpoint with `{username, password, clientid}` and the `x-smartpot-broker-token` header. The API responds:

   ```json
   {
     "result": "allow",
     "acl": [
       {"permission": "allow", "action": "publish",   "topic": "smartpot/v1/<cropId>/telemetry"},
       {"permission": "allow", "action": "publish",   "topic": "smartpot/v1/<cropId>/status"},
       {"permission": "allow", "action": "publish",   "topic": "smartpot/v1/<cropId>/commands/ack"},
       {"permission": "allow", "action": "subscribe", "topic": "smartpot/v1/<cropId>/commands"},
       {"permission": "deny",  "action": "all",       "topic": "#"}
     ]
   }
   ```

   If the token does not match, the crop does not exist, or the key is invalid, the API responds `{"result":"deny"}`.

### 3.2 Authorization

There are no per-device authorization stores in the broker. Every device connection carries its ACL from the authentication response, allowing only its own crop's topics and denying the rest. Global settings enforce `no_match = deny` and `deny_action = disconnect`, so any operation outside the ACL terminates the connection. The service account is a superuser and bypasses authorization.

### 3.3 Decoupling in the API (Ports and Adapters)

The API does not depend on EMQX: it depends on **ports** (domain interfaces) and EMQX is an interchangeable **adapter**, just like PostgreSQL is the adapter for the data port (Dependency Inversion Principle from hexagonal architecture). No domain package imports the broker adapter; the broker (and its EMQX specifics) are only known inside the adapter and wired at startup (`cmd/api`).

| Port (domain)             | What It Abstracts                                   | EMQX Adapter                                                                         |
|---------------------------|-----------------------------------------------------|--------------------------------------------------------------------------------------|
| `commands.Publisher`      | Send a command to a crop                            | MQTT client (publishes to `commands`)                                                |
| `crops.DeviceProvisioner` | Provision/rotate/revoke device credentials          | Disconnects sessions via EMQX REST API (create is a no-op: the key lives in the DB)  |
| `mqtt.DeviceVerifier`     | Verify a device credential                          | Implemented by the crop service (decrypts and compares against the DB)               |

## 4. Listeners

| Port  | Protocol                       | Purpose                                                          |
|-------|--------------------------------|------------------------------------------------------------------|
| 1883  | MQTT                           | Internal: API and simulator on the Docker network                |
| 8883  | MQTT over TLS (1.2/1.3)        | Real devices; `mqtt.smartpot.app:8883`                           |
| 9001  | MQTT over WebSocket (`/mqtt`)  | Web clients behind Nginx at `wss://mqtt.smartpot.app/mqtt`       |
| 18083 | REST API / Dashboard           | Internal: the API disconnects sessions upon rotation or deletion |

The TLS listener uses SmartPot's private CA. Devices verify the server with `ca.crt` (public, embedded in firmware) and the broker does not require a client certificate.

## 5. Operation

- **API Connection**: authenticates with `MQTT_ADMIN_USERNAME`/`MQTT_ADMIN_PASSWORD` (superuser). Subscribes to `smartpot/v1/+/telemetry`, `smartpot/v1/+/commands/ack`, and `smartpot/v1/+/status`, and publishes commands to `smartpot/v1/{cropId}/commands`.
- **Device Connection**: TLS on 8883 (or internal 1883 for the simulator), username = crop ID, password = device key. Publishes retained `online` to `status` on connect, with retained Last Will `offline`.
- **Key Rotation/Deletion**: the API disconnects active crop sessions via the EMQX REST API (`GET /api/v5/clients?username=<cropId>` followed by `DELETE /api/v5/clients/{clientid}`), invalidating the old key immediately.

## 6. Configuration (Environment Variables)

| Variable                                      | Description                                                       | Default                                         |
|-----------------------------------------------|-------------------------------------------------------------------|-------------------------------------------------|
| `MQTT_ADMIN_USERNAME`                         | API service account                                               | `smartpot-api`                                  |
| `MQTT_ADMIN_PASSWORD`                         | Service account password (min. 16 chars; first boot only)         | — (required)                                    |
| `MQTT_AUTHN_TOKEN`                            | Shared secret with the API to authenticate devices                | — (required)                                    |
| `MQTT_AUTHN_URL`                              | Internal API authentication endpoint                              | `http://api-smartpot:8091/internal/mqtt/authn`  |
| `MQTT_BROKER_API_KEY` / `MQTT_BROKER_API_SECRET` | EMQX REST API key (used by the API to disconnect sessions)     | — (required)                                    |
| `MQTT_SCHEDULERS`                             | BEAM scheduler threads (`+S N:N`)                                 | `2`                                             |
| `MQTT_TLS_MAX_CONNECTIONS`                    | TLS listener max connections                                      | `200`                                           |

## 7. Tests

`tests/smoke.sh` boots the image with a stub mimicking the API authentication endpoint and validates: own telemetry received, per-crop isolation (foreign publish and subscribe blocked), invalid keys and anonymous connections rejected, TLS with CA verification, and active listeners. Real API isolation is verified again in the central E2E suite.

---

# Español

## 1. Propósito

El broker es el único punto de contacto de los dispositivos (ESP32 reales o el simulador) con la plataforma. Transporta la telemetría de los cultivos hacia la API y los comandos de la API hacia los actuadores. Esta versión corre sobre **EMQX 5.8** y sustituye a la de Eclipse Mosquitto sin cambiar el contrato de los dispositivos.

## 2. Qué cambia frente a Mosquitto

| Aspecto | Mosquitto (anterior) | EMQX (actual) |
|---|---|---|
| Contrato del dispositivo | usuario = id del cultivo, clave del dispositivo, TLS con la CA, tópicos `smartpot/v1/...` | **Igual** (sin cambios en el firmware ni en el simulador) |
| Aprovisionamiento | La API creaba/borraba cuentas y roles por los tópicos de control de la *dynamic security* | La API **no** registra cuentas: la clave vive en su base y EMQX la consulta al conectar |
| Autenticación de dispositivos | contraseña almacenada en el broker | HTTP a la API, que verifica la clave y devuelve el permiso + el ACL del cultivo |
| Autorización | rol `device` con ACL `%u` creado por la API | ACL por cultivo adjunto en la respuesta de autenticación; `no_match = deny` |
| Cuenta de la API | cliente administrador de la *dynamic security* | superusuario sembrado en la base interna de EMQX |
| Rotar/borrar la clave | `disableClient`/`enableClient` por tópico de control | la API corta las sesiones vivas por la API REST de EMQX |

Resultado: menos estado y menos acoplamiento. El broker no guarda cuentas de dispositivo; crear, rotar o borrar un cultivo tiene efecto inmediato sin sincronizar nada con el broker.

## 3. Autenticación y autorización

### 3.1 Cadena de autenticación

1. **Base interna de EMQX** (`built_in_database`): contiene una sola cuenta, la de servicio de la API (`MQTT_ADMIN_USERNAME`), sembrada como **superusuario** desde un archivo de bootstrap en el primer arranque. Para cualquier otro usuario, la base «ignora» y la cadena continúa.
2. **HTTP a la API** (`http`): para los dispositivos. EMQX hace `POST` al endpoint interno de la API con `{username, password, clientid}` y la cabecera `x-smartpot-broker-token`. La API responde:

   ```json
   {
     "result": "allow",
     "acl": [
       {"permission": "allow", "action": "publish",   "topic": "smartpot/v1/<cropId>/telemetry"},
       {"permission": "allow", "action": "publish",   "topic": "smartpot/v1/<cropId>/status"},
       {"permission": "allow", "action": "publish",   "topic": "smartpot/v1/<cropId>/commands/ack"},
       {"permission": "allow", "action": "subscribe", "topic": "smartpot/v1/<cropId>/commands"},
       {"permission": "deny",  "action": "all",       "topic": "#"}
     ]
   }
   ```

   Si el token no coincide, el cultivo no existe o la clave es inválida, la API responde `{"result":"deny"}`.

### 3.2 Autorización

No hay fuentes de autorización por dispositivo. Cada conexión de dispositivo trae su ACL desde la autenticación, que solo permite los tópicos de su propio cultivo y niega el resto. La configuración global fija `no_match = deny` y `deny_action = disconnect`, así que una operación fuera del ACL corta la conexión. La cuenta de servicio es superusuario y no pasa por autorización.

### 3.3 Desacoplamiento en la API (puertos y adaptadores)

La API no depende de EMQX: depende de **puertos** (interfaces del dominio) y EMQX es un **adaptador** intercambiable, igual que PostgreSQL es el adaptador del puerto de datos. Es el principio de inversión de dependencias (la D de SOLID) de la arquitectura hexagonal. Ningún paquete de dominio importa el adaptador del broker; el broker (y sus detalles de EMQX) solo se conocen en el adaptador y se cablean en el arranque (`cmd/api`).

| Puerto (dominio) | Qué abstrae | Adaptador EMQX |
|---|---|---|
| `commands.Publisher` | Enviar una orden a un cultivo | Cliente MQTT (publica en `commands`) |
| `crops.DeviceProvisioner` | Alta/rotación/baja de la credencial del dispositivo | Corta sesiones por la API REST de EMQX (crear es no-op: la clave vive en la base) |
| `mqtt.DeviceVerifier` | Verificar la credencial de un dispositivo | Lo implementa el servicio de cultivos (descifra y compara contra la base) |

## 4. Listeners

| Puerto | Protocolo | Uso |
|---|---|---|
| 1883 | MQTT | Interno: la API y el simulador en la red de Docker |
| 8883 | MQTT sobre TLS (1.2/1.3) | Dispositivos reales; `mqtt.smartpot.app:8883` |
| 9001 | MQTT sobre WebSocket (`/mqtt`) | Clientes web, detrás de Nginx como `wss://mqtt.smartpot.app/mqtt` |
| 18083 | API REST / panel | Interno: la API corta sesiones al rotar o borrar |

El listener TLS usa la CA propia de SmartPot. El dispositivo verifica el servidor con `ca.crt` (pública, incrustada en el firmware) y el broker no exige certificado de cliente.

## 5. Operación

- **Conexión de la API**: se autentica con `MQTT_ADMIN_USERNAME`/`MQTT_ADMIN_PASSWORD` (superusuario). Se suscribe a `smartpot/v1/+/telemetry`, `smartpot/v1/+/commands/ack` y `smartpot/v1/+/status`, y publica comandos en `smartpot/v1/{cropId}/commands`.
- **Conexión de un dispositivo**: TLS a 8883 (o 1883 interno para el simulador), usuario = id del cultivo, clave del dispositivo. Publica `online` retenido en `status` al conectar, con última voluntad `offline` retenida.
- **Rotación/borrado de la clave**: la API corta las sesiones vivas del cultivo con la API REST de EMQX (`GET /api/v5/clients?username=<cropId>` y luego `DELETE /api/v5/clients/{clientid}`), de modo que la clave vieja deja de servir de inmediato. Es un intento best-effort: si falla, se registra y la clave nueva igual aplica en la próxima conexión.

## 6. Configuración (variables de entorno)

| Variable | Descripción | Por defecto |
|---|---|---|
| `MQTT_ADMIN_USERNAME` | Cuenta de servicio de la API | `smartpot-api` |
| `MQTT_ADMIN_PASSWORD` | Clave de la cuenta de servicio (mín. 16; solo al primer arranque) | — (obligatoria) |
| `MQTT_AUTHN_TOKEN` | Secreto compartido con la API para autenticar dispositivos | — (obligatoria) |
| `MQTT_AUTHN_URL` | Endpoint interno de autenticación de la API | `http://api-smartpot:8091/internal/mqtt/authn` |
| `MQTT_BROKER_API_KEY` / `MQTT_BROKER_API_SECRET` | Clave de la API REST de EMQX (la usa la API para desconectar) | — (obligatorias) |
| `MQTT_SCHEDULERS` | Hilos del BEAM (`+S N:N`) | `2` |
| `MQTT_TLS_MAX_CONNECTIONS` | Conexiones del listener TLS | `200` |

## 7. Pruebas

`tests/smoke.sh` levanta la imagen con un stub que imita el endpoint de autenticación de la API y valida: telemetría propia recibida, aislamiento por cultivo (publicación y suscripción ajenas cortadas), rechazo de claves incorrectas y anónimos, TLS con la CA y listeners activos. El aislamiento con la API real se repite en el E2E central.
