<!-- portada
eyebrow: Documentación del componente
titulo: SmartPot-Broker
acento: Broker
subtitulo: El cartero de los dispositivos
bajada: Mosquitto 2.1 con TLS sobre una CA propia, seguridad dinámica y una cuenta por cultivo: listeners, permisos, certificados, contrato de tópicos, configuración y pruebas.
documento: SmartPot-Broker
version: 1.0 · septiembre 2026
equipo: SmartPotTech
proyecto: smartpot.app
-->

# SmartPot-Broker

## Ficha del documento

| Campo                          | Valor                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
|--------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Proyecto                       | SmartPot · [smartpot.app](https://smartpot.app)                                                                                                                                                                                                                                                                                                                                                                                                         |
| Componente                     | [SmartPot-Broker](https://github.com/SmartPotTech/SmartPot-Broker)                                                                                                                                                                                                                                                                                                                                                                                      |
| Versión                        | 1.0 · septiembre 2026                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Alcance                        | Listeners, seguridad dinámica, permisos por cultivo, certificados, tópicos, configuración y pruebas                                                                                                                                                                                                                                                                                                                                                     |
| Documentación de la plataforma | [Documentación técnica](https://github.com/SmartPotTech/.github/blob/main/docs/SmartPot_Technical_Documentation.md), [recorrido del proyecto](https://github.com/SmartPotTech/.github/blob/main/docs/SmartPot_Project_Journey.md), [ciclo de vida](https://github.com/SmartPotTech/.github/blob/main/docs/SmartPot_Software_Lifecycle.md) y [diagramas generales](https://github.com/SmartPotTech/.github/blob/main/docs/README.md#diagramas-generales) |
| Mantenimiento                  | Se genera desde `docs/` de este repositorio con las herramientas de `.github/docs/tools`; se actualiza con cada cambio del componente                                                                                                                                                                                                                                                                                                                   |

<!-- parte: PARTE I | El componente -->

## 1. Propósito

### En palabras simples

El broker es el cartero entre los dispositivos y la plataforma. El ESP32 de cada cultivo real, físico o en Wokwi, y el
simulador de los cultivos virtuales publican aquí sus lecturas y reciben sus órdenes; la API escucha y responde. Nadie
entra sin usuario y clave, y cada cultivo solo puede tocar sus propios tópicos.

## 2. Arquitectura del componente

<!-- diagrama: SmartPot_Broker_Global_Component | titulo=SmartPot-Broker por dentro | lamina=H -->

```mermaid
%%{init: {"theme": "base", "fontFamily": "Segoe UI, Arial, sans-serif", "themeVariables": {"fontFamily": "Segoe UI, Arial, sans-serif", "fontSize": "15px", "primaryColor": "#DDF5EA", "primaryTextColor": "#17261F", "primaryBorderColor": "#067A52", "secondaryColor": "#E3F2FB", "secondaryTextColor": "#17261F", "secondaryBorderColor": "#1F6FA0", "tertiaryColor": "#F2F7F4", "tertiaryTextColor": "#17261F", "tertiaryBorderColor": "#D5E3DC", "lineColor": "#5B6B63", "textColor": "#17261F", "mainBkg": "#DDF5EA", "nodeBorder": "#067A52", "clusterBkg": "#F7FAF8", "clusterBorder": "#D5E3DC", "edgeLabelBackground": "#FFFFFF", "actorBkg": "#067A52", "actorBorder": "#0B3D2B", "actorTextColor": "#FFFFFF", "actorLineColor": "#5B6B63", "signalColor": "#17261F", "signalTextColor": "#17261F", "labelBoxBkgColor": "#0B3D2B", "labelBoxBorderColor": "#0B3D2B", "labelTextColor": "#FFFFFF", "loopTextColor": "#0B3D2B", "noteBkgColor": "#FDF4DD", "noteBorderColor": "#C98D12", "noteTextColor": "#17261F", "activationBkgColor": "#DDF5EA", "activationBorderColor": "#067A52", "attributeBackgroundColorOdd": "#FFFFFF", "attributeBackgroundColorEven": "#F2F7F4"}, "layout": "elk", "elk": {"nodePlacementStrategy": "BRANDES_KOEPF", "mergeEdges": false, "cycleBreakingStrategy": "GREEDY"}}}%%
flowchart LR
  subgraph clientes["Clientes"]
    direction TB
    esp["ESP32 de un cultivo real<br/>físico o en Wokwi"]
    web["Clientes web"]
    api["SmartPot-API<br/>cuenta administradora"]
    sim["SmartPot-DataGenerator<br/>cultivos virtuales"]
  end
  nginx["nginx<br/>wss://mqtt.smartpot.app/mqtt"]
  subgraph broker["SmartPot-Broker · Mosquitto 2.1 · usuario 1883"]
    direction TB
    tls["Listener 8883<br/>MQTT sobre TLS 1.2+<br/>certificado de la CA propia"]
    ws["Listener 9001<br/>WebSocket"]
    internal["Listener 1883<br/>solo red interna"]
    dynsec["Seguridad dinámica<br/>administrador · rol device con %u<br/>una cuenta por cultivo"]
    data[("/mosquitto/data<br/>dynamic-security.json<br/>sesiones")]
  end
  certs[("/etc/mosquitto/certs<br/>ca.crt · server.crt · server.key<br/>solo lectura")]
  esp -->|"usuario cropId · clave"| tls
  web --> nginx --> ws
  api --> internal
  sim --> internal
  tls & ws & internal --> dynsec --> data
  certs --> tls
  api -.->|"createClient · setClientPassword<br/>disableClient · deleteClient"| dynsec
  classDef leaf fill:#DDF5EA,stroke:#067A52,color:#17261F
  classDef water fill:#E3F2FB,stroke:#1F6FA0,color:#17261F
  classDef sun fill:#FDF4DD,stroke:#C98D12,color:#17261F
  classDef clay fill:#FBE9E1,stroke:#B85A38,color:#17261F
  classDef core fill:#067A52,stroke:#0B3D2B,color:#FFFFFF
  classDef deep fill:#0B3D2B,stroke:#06281C,color:#FFFFFF
  classDef muted fill:#F2F7F4,stroke:#5B6B63,color:#17261F
  class esp,web,api,sim water
  class nginx sun
  class tls,ws,internal leaf
  class dynsec core
  class data,certs muted
```

| Listener                   | Uso                                 | Publicación en producción                      |
|----------------------------|-------------------------------------|------------------------------------------------|
| `8883` MQTT sobre TLS 1.2+ | Dispositivos de los cultivos reales | Directo en `mqtt.smartpot.app:8883`            |
| `9001` WebSocket           | Clientes web                        | `wss://mqtt.smartpot.app/mqtt` detrás de nginx |
| `1883` MQTT                | La API y el simulador               | Solo la red interna de Docker                  |

<!-- parte: PARTE II | Seguridad -->

## 3. Permisos por cultivo

<!-- diagrama: SmartPot_Broker_01_Device_Permissions | titulo=Qué puede hacer cada conexión -->

```mermaid
%%{init: {"theme": "base", "fontFamily": "Segoe UI, Arial, sans-serif", "themeVariables": {"fontFamily": "Segoe UI, Arial, sans-serif", "fontSize": "15px", "primaryColor": "#DDF5EA", "primaryTextColor": "#17261F", "primaryBorderColor": "#067A52", "secondaryColor": "#E3F2FB", "secondaryTextColor": "#17261F", "secondaryBorderColor": "#1F6FA0", "tertiaryColor": "#F2F7F4", "tertiaryTextColor": "#17261F", "tertiaryBorderColor": "#D5E3DC", "lineColor": "#5B6B63", "textColor": "#17261F", "mainBkg": "#DDF5EA", "nodeBorder": "#067A52", "clusterBkg": "#F7FAF8", "clusterBorder": "#D5E3DC", "edgeLabelBackground": "#FFFFFF", "actorBkg": "#067A52", "actorBorder": "#0B3D2B", "actorTextColor": "#FFFFFF", "actorLineColor": "#5B6B63", "signalColor": "#17261F", "signalTextColor": "#17261F", "labelBoxBkgColor": "#0B3D2B", "labelBoxBorderColor": "#0B3D2B", "labelTextColor": "#FFFFFF", "loopTextColor": "#0B3D2B", "noteBkgColor": "#FDF4DD", "noteBorderColor": "#C98D12", "noteTextColor": "#17261F", "activationBkgColor": "#DDF5EA", "activationBorderColor": "#067A52", "attributeBackgroundColorOdd": "#FFFFFF", "attributeBackgroundColorEven": "#F2F7F4"}}}%%
flowchart TB
  connect(["CONNECT"]) --> anon{"¿Trae usuario y clave?"}
  anon -->|"No"| reject["Rechazado: sin acceso anónimo"]
  anon -->|"Sí"| id{"¿Client id vacío?"}
  id -->|"Sí"| reject
  id -->|"No"| auth{"¿Cuenta de la seguridad dinámica<br/>con esa clave?"}
  auth -->|"No"| reject
  auth -->|"Administrador"| admin["smartpot/# y comandos de control<br/>solo SmartPot-API"]
  auth -->|"Rol device · usuario = cropId"| device["Solo su propio cultivo (%u)"]
  device --> pub["Publica<br/>smartpot/v1/cropId/telemetry<br/>…/commands/ack · …/status"]
  device --> sub["Se suscribe<br/>smartpot/v1/cropId/commands"]
  device --> other{"¿Tópico de otro cultivo?"}
  other -->|"Sí"| drop["Se descarta"]
  classDef leaf fill:#DDF5EA,stroke:#067A52,color:#17261F
  classDef water fill:#E3F2FB,stroke:#1F6FA0,color:#17261F
  classDef sun fill:#FDF4DD,stroke:#C98D12,color:#17261F
  classDef clay fill:#FBE9E1,stroke:#B85A38,color:#17261F
  classDef core fill:#067A52,stroke:#0B3D2B,color:#FFFFFF
  classDef deep fill:#0B3D2B,stroke:#06281C,color:#FFFFFF
  classDef muted fill:#F2F7F4,stroke:#5B6B63,color:#17261F
  class connect core
  class anon,id,auth,other sun
  class reject,drop clay
  class admin,device,pub,sub leaf
```

La API es la única cuenta administradora: al arrancar crea el rol `device` y vuelve a crear la cuenta de cada cultivo
desde la base de datos (el broker no necesita respaldo propio); al crear, rotar o borrar un cultivo actualiza su cuenta.
Los cultivos virtuales también tienen cuenta: la usa el simulador.

## 4. Certificados

<!-- diagrama: SmartPot_Broker_02_Certificates | titulo=Certificados del broker -->

```mermaid
%%{init: {"theme": "base", "fontFamily": "Segoe UI, Arial, sans-serif", "themeVariables": {"fontFamily": "Segoe UI, Arial, sans-serif", "fontSize": "15px", "primaryColor": "#DDF5EA", "primaryTextColor": "#17261F", "primaryBorderColor": "#067A52", "secondaryColor": "#E3F2FB", "secondaryTextColor": "#17261F", "secondaryBorderColor": "#1F6FA0", "tertiaryColor": "#F2F7F4", "tertiaryTextColor": "#17261F", "tertiaryBorderColor": "#D5E3DC", "lineColor": "#5B6B63", "textColor": "#17261F", "mainBkg": "#DDF5EA", "nodeBorder": "#067A52", "clusterBkg": "#F7FAF8", "clusterBorder": "#D5E3DC", "edgeLabelBackground": "#FFFFFF", "actorBkg": "#067A52", "actorBorder": "#0B3D2B", "actorTextColor": "#FFFFFF", "actorLineColor": "#5B6B63", "signalColor": "#17261F", "signalTextColor": "#17261F", "labelBoxBkgColor": "#0B3D2B", "labelBoxBorderColor": "#0B3D2B", "labelTextColor": "#FFFFFF", "loopTextColor": "#0B3D2B", "noteBkgColor": "#FDF4DD", "noteBorderColor": "#C98D12", "noteTextColor": "#17261F", "activationBkgColor": "#DDF5EA", "activationBorderColor": "#067A52", "attributeBackgroundColorOdd": "#FFFFFF", "attributeBackgroundColorEven": "#F2F7F4"}}}%%
flowchart LR
  entropy["Entropía opcional<br/>tercer argumento"] --> ca["generate-certs.sh<br/>CA privada de SmartPot<br/>ca.key · ca.crt"]
  ca --> server["Certificado del broker<br/>server.key · server.crt<br/>nombre mqtt.smartpot.app · 825 días"]
  ca -.->|"CLIENT_NAME"| client["Certificado de cliente opcional<br/>para TLS mutuo"]
  server --> mount["Servidor: /etc/mosquitto/certs<br/>solo lectura · habilita el listener 8883"]
  ca --> public["ca.crt es público<br/>va con el firmware y en la PWA"]
  ca --> offline["ca.key fuera del servidor"]
  classDef leaf fill:#DDF5EA,stroke:#067A52,color:#17261F
  classDef water fill:#E3F2FB,stroke:#1F6FA0,color:#17261F
  classDef sun fill:#FDF4DD,stroke:#C98D12,color:#17261F
  classDef clay fill:#FBE9E1,stroke:#B85A38,color:#17261F
  classDef core fill:#067A52,stroke:#0B3D2B,color:#FFFFFF
  classDef deep fill:#0B3D2B,stroke:#06281C,color:#FFFFFF
  classDef muted fill:#F2F7F4,stroke:#5B6B63,color:#17261F
  class entropy muted
  class ca core
  class server,client leaf
  class mount,public water
  class offline clay
```

El listener TLS solo se habilita si existen `ca.crt`, `server.crt` y `server.key`. `require_certificate` está en
`false`: el dispositivo se autentica con usuario y clave y verifica el servidor con `ca.crt`. Renueva el certificado del
servidor antes de 825 días con la misma CA.

## 5. Tópicos del contrato v1

| Tópico                              | Sentido                                 | QoS |
|-------------------------------------|-----------------------------------------|-----|
| `smartpot/v1/{cropId}/telemetry`    | Dispositivo → API                       | 0   |
| `smartpot/v1/{cropId}/commands`     | API → dispositivo                       | 1   |
| `smartpot/v1/{cropId}/commands/ack` | Dispositivo → API                       | 1   |
| `smartpot/v1/{cropId}/status`       | Dispositivo, retenido y última voluntad | 1   |

<!-- parte: PARTE III | Operación -->

## 6. Configuración

| Variable                                     | Uso                                                                 |
|----------------------------------------------|---------------------------------------------------------------------|
| `MQTT_ADMIN_USERNAME`, `MQTT_ADMIN_PASSWORD` | Cuenta administradora; la clave solo se aplica con el volumen vacío |
| `MQTT_TLS_MAX_CONNECTIONS`                   | Conexiones simultáneas por listener (200 por defecto)               |

Reglas fijas: client id vacío rechazado, sesiones persistentes que vencen una hora después de desconectarse y sin acceso
anónimo.

## 7. Pruebas

`sh tests/smoke.sh smartpot-broker:ci` genera una CA desechable y verifica que la telemetría propia llega, que se
descartan publicaciones y suscripciones a nombre de otro cultivo, que se rechazan claves incorrectas, ids vacíos y
anónimos, y que el listener TLS solo acepta credenciales válidas (10 comprobaciones).

## 8. Operación

| Tarea                              | Cómo                                                                                                                           |
|------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| Imagen                             | `ghcr.io/smartpottech/smartpot-broker`: usuario `1883`, solo lectura con `tmpfs` y volumen en `/mosquitto/data`, `HEALTHCHECK` |
| Cambiar la clave del administrador | `mosquitto_ctrl dynsec setClientPassword` o recrear el volumen (la API reaprovisiona los cultivos)                             |
| Despliegue                         | Cada cambio en `main` pasa por el CI, publica la imagen y pide el despliegue central de `.github`                              |
