# SmartPot-Broker-EMQX — Technical Documentation / Documentación técnica

---

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
