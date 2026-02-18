# Informix CDC con Debezium Server + Kafka

Pipeline de Change Data Capture (CDC) que captura cambios en tiempo real desde IBM Informix y los publica en Apache Kafka.

## Arquitectura

```
                                                          ┌─────────────────┐
┌──────────────┐     CDC      ┌──────────────────┐       │  Redpanda       │
│   Informix   │ ──────────── │  Debezium Server │ ──►   │  Console :9080  │
│ (fedefarma)  │  Change      │     :8080        │       └────────┬────────┘
└──────────────┘  Streams     └────────┬─────────┘                │
                                       │ Producer                 │
                                       ▼                          │
                                ┌─────────────┐                   │
                                │    Kafka     │ ◄────────────────┘
                                │   (KRaft)    │        UI
                                │    :9092     │
                                └──────┬──────┘
                                       │ Consumer
                                       ▼
                              ┌──────────────────┐
                              │ informix-consumer │
                              │     :3001        │
                              └──────────────────┘
```

## Componentes

| Servicio | Imagen | Puerto | Descripcion |
|----------|--------|--------|-------------|
| **Kafka** | `apache/kafka:3.9.0` | `127.0.0.1:9092` | Broker en modo KRaft (sin Zookeeper) |
| **Debezium Server** | Custom (`quay.io/debezium/server:3.4.1.Final`) | `127.0.0.1:8080` | CDC connector para Informix |
| **Redpanda Console** | `redpandadata/console:v3.5.1` | `127.0.0.1:9080` | UI para Kafka |
| **Informix** (test) | `icr.io/informix/informix-developer-database:latest` | `127.0.0.1:9088` | Stack separado en `informix-test/` |

Todos los puertos estan vinculados a `127.0.0.1` (solo acceso local).

## Tablas monitorizadas

| Tabla | Registros | Key | Descripcion |
|-------|-----------|-----|-------------|
| `ctercero` | ~81,000 | `codigo` | Terceros (socios, empresas, clientes) |
| `cterdire` | ~139,000 | `codigo,tipdir` | Direcciones de terceros |
| `gproveed` | ~8,600 | `codigo` | Proveedores |
| `cterasoc` | ~3,400 | - | Asociaciones de terceros |
| `gvenacuh` | ~33,500 | - | Acumulados de venta |

Topics en Kafka: `informix.informix.<tabla>` (ej. `informix.informix.ctercero`)

## Estructura del proyecto

```
informix-debezium/
├── docker-compose.yml                  # Stack: Kafka + Debezium + Redpanda Console
├── Dockerfile                          # Imagen Debezium con drivers Informix
├── .env                                # Credenciales activas (excluido de git)
├── .env.example                        # Plantilla sin secretos
├── .env.test / .env.production         # Perfiles de entorno
├── switch-env.sh                       # Script para cambiar entre entornos
├── config/
│   ├── application.properties          # Config Debezium (usa ${DB_*} del .env)
│   └── application.properties.example  # Plantilla documentada
├── docs/
│   ├── OPERACIONES.md                  # Guia de operaciones completa
│   ├── PRODUCCION_INFORMIX.md          # Requisitos para produccion
│   ├── REQUISITOS_INFORMIX_CDC.md      # Prerequisitos CDC en Informix
│   ├── REQUISITOS_SERVIDOR.md          # Sizing de hardware
│   ├── CAMBIOS_INFORMIX.md             # Cambios aplicados en Informix
│   └── GUIA_RAPIDA_CDC.md             # Guia rapida de CDC
├── informix-test/
│   ├── docker-compose.yml              # Instancia Informix de desarrollo
│   └── init.sql                        # Inicializacion de la BD
└── SQL/
    ├── *_DDL.sql / *_DLL.sql           # DDL de cada tabla
    └── fedefarm_informix_*.sql         # Datos (excluidos de git, contienen PII)
```

## Inicio rapido

### 1. Informix de test (opcional, solo desarrollo)

```bash
cd informix-test
docker compose up -d
# Esperar a healthy (~1-2 min), luego crear BD y cargar datos
# Ver docs/GUIA_RAPIDA_CDC.md para detalles
```

### 2. Configurar credenciales

```bash
cp .env.test .env       # para desarrollo
# o
cp .env.production .env # para produccion
```

### 3. Levantar el stack

```bash
docker compose up -d --build
```

Debezium hara snapshot inicial de las 5 tablas y luego entrara en modo streaming (CDC en tiempo real).

### 4. Verificar

```bash
# Estado de los servicios
docker compose ps

# Progreso del snapshot
docker logs debezium-server 2>&1 | grep -E 'Exported|Finished|Snapshot completed|streaming'

# Topics en Kafka
docker exec kafka /opt/kafka/bin/kafka-topics.sh --list --bootstrap-server localhost:9092

# UI de Kafka
open http://localhost:9080
```

## Configuracion destacada

| Propiedad | Valor | Efecto |
|-----------|-------|--------|
| `snapshot.mode` | `initial` | Snapshot solo la primera vez (no re-snaphotea si los logs se reciclan) |
| `offset.flush.interval.ms` | `10000` | Persiste offsets cada 10s (minimiza perdida en crash) |
| `schemas.enable` | `false` | Elimina schema embebido de cada mensaje (~85% menos en Kafka) |
| `KAFKA_LOG_CLEANUP_POLICY` | `compact` | Compactacion por key (evita crecimiento indefinido de topics) |

Las credenciales se inyectan via `.env` con `${DB_*}` — Quarkus las resuelve automaticamente. Nunca estan en ficheros versionados.

## Cambio de entorno

```bash
./switch-env.sh test        # cambia a test (conserva volumenes)
./switch-env.sh production  # cambia a produccion
```

El script guarda y restaura volumenes de Kafka y Debezium por entorno, evitando re-snapshots innecesarios. Ver `docs/OPERACIONES.md` para detalles.

## Forzar re-snapshot

Si se necesita rebuildir los datos desde cero (nueva tabla, datos corruptos, etc.):

```bash
docker compose down
docker volume rm informix-debezium_debezium-data
docker compose up -d
```

> Con `snapshot.mode=initial`, anadir una tabla nueva a `table.include.list` NO hace snapshot automatico de esa tabla. Hay que forzar re-snapshot de todas las tablas (ver arriba) o aceptar que solo recibira eventos CDC futuros.

## Drivers Informix (Dockerfile)

La imagen base incluye el conector Informix, pero necesita JARs adicionales:

| JAR | Version | Motivo |
|-----|---------|--------|
| `jdbc` | 4.50.12 | Driver JDBC de IBM Informix |
| `ifx-changestream-client` | 1.1.3 | Cliente Change Streams de Informix |
| `bson` | 3.8.0 | Dependencia del driver JDBC |

> Las versiones deben coincidir con las del `pom.xml` de Debezium 3.4.1.Final. Versiones incorrectas causan `NoClassDefFoundError`.

## Documentacion

| Documento | Contenido |
|-----------|-----------|
| [OPERACIONES.md](docs/OPERACIONES.md) | Cambio de entornos, snapshots, volumenes, monitorizacion, troubleshooting |
| [PRODUCCION_INFORMIX.md](docs/PRODUCCION_INFORMIX.md) | Requisitos para conectar a Informix de produccion |
| [REQUISITOS_INFORMIX_CDC.md](docs/REQUISITOS_INFORMIX_CDC.md) | Prerequisitos CDC: syscdcv1, full row logging, permisos |
| [REQUISITOS_SERVIDOR.md](docs/REQUISITOS_SERVIDOR.md) | Sizing de hardware para produccion |
| [CAMBIOS_INFORMIX.md](docs/CAMBIOS_INFORMIX.md) | Cambios aplicados en servidores Informix |
| [GUIA_RAPIDA_CDC.md](docs/GUIA_RAPIDA_CDC.md) | Guia paso a paso para configurar CDC |

## Seguridad

- Credenciales externalizadas en `.env` (excluido de git via `.gitignore`)
- Puertos vinculados a `127.0.0.1` (no accesibles desde red)
- Debezium ejecuta como usuario no-root (`USER 185`)
- Logs JDBC suprimidos a nivel WARN (evitan filtrar passwords en connection strings)
- Dumps SQL con PII excluidos de git
