# SmartPot-Broker

Broker MQTT para el ecosistema SmartPot basado en Eclipse Mosquitto.

## Requisitos

- Docker

## Levantar el broker

```bash
docker compose up -d
```

El broker escucha en el puerto **1883** y acepta conexiones anónimas. Los datos de sesión persisten en un volumen con nombre (`mosquitto_data`).

## Detener el broker

```bash
docker compose down
```

Para eliminar también los datos persistentes:

```bash
docker compose down -v
```

## Configuración

Toda la configuración del broker está en `mosquitto.conf`. Para aplicar cambios en caliente:

```bash
docker compose restart
```

## Puertos

| Puerto | Protocolo |
|--------|-----------|
| 1883   | MQTT      |
