# Guia de Operaciones - Informix Debezium CDC

---

## 1. Cambio entre entornos (Test / Produccion)

### 1.1 Estructura de ficheros .env

El stack utiliza ficheros `.env` para definir la conexion a Informix. Existen perfiles preconfigurados:

| Fichero | Entorno | Servidor | Base de datos |
|---------|---------|----------|---------------|
| `.env.test` | Desarrollo | `host.docker.internal:9088` | `testdb` |
| `.env.production` | Produccion | `192.168.96.117:9800` | `fedefarm` |
| `.env` | **Activo** (el que usa Docker) | Copia de uno de los anteriores | |

### 1.2 Cambio rapido con script

```bash
# Cambiar a test
./switch-env.sh test

# Cambiar a produccion
./switch-env.sh production
```

El script automatiza:
1. Para el stack completo (`docker compose down`)
2. Guarda los volumenes actuales (Kafka + Debezium) etiquetados con el entorno actual
3. Si existen volumenes guardados del entorno destino, los restaura (sin snapshot)
4. Si no existen, arranca limpio (snapshot completo)
5. Copia `.env.test` o `.env.production` a `.env`
6. Levanta el stack (`docker compose up -d`)

Esto permite cambiar entre entornos sin repetir el snapshot (~36 min en produccion). Los volumenes se guardan como:
- `informix-debezium_kafka-data-test` / `informix-debezium_debezium-data-test`
- `informix-debezium_kafka-data-production` / `informix-debezium_debezium-data-production`

La primera vez que se cambia a un entorno, se hace snapshot completo. Las siguientes veces, se restauran los datos guardados y Debezium continua donde lo dejo.

### 1.3 Cambio manual paso a paso (sin conservar volumenes)

Si se prefiere un cambio limpio sin conservar datos:

```bash
# 1. Parar todo y borrar volumenes
docker compose down --volumes

# 2. Copiar el perfil deseado
cp .env.test .env        # para test
# o
cp .env.production .env  # para produccion

# 3. Levantar (hara snapshot completo)
docker compose up -d

# 4. Monitorizar el snapshot
docker logs -f debezium-server
```

### 1.4 Configuracion dinamica

El fichero `application.properties` usa variables de entorno del `.env` para toda la configuracion que cambia entre entornos:

| Propiedad | Valor en properties | Resuelto desde .env |
|-----------|--------------------|--------------------|
| `database.hostname` | `${DB_HOSTNAME}` | IP/host del servidor |
| `database.port` | `${DB_PORT}` | Puerto Informix |
| `database.user` | `${DB_USER}` | Usuario de conexion |
| `database.password` | `${DB_PASSWORD}` | Password |
| `database.dbname` | `${DB_NAME}` | Nombre de la BD |
| `table.include.list` | `${DB_NAME}.informix.ctercero,...` | Tablas con prefijo dinamico |

Al cambiar de entorno solo hay que cambiar el `.env` — no es necesario editar `application.properties`.

### 1.5 Por que es necesario borrar los offsets?

Cuando se cambia de servidor Informix, los offsets de Debezium (posicion en el log CDC) corresponden al servidor anterior. Si no se borran:
- Debezium intentara continuar desde un offset que no existe en el nuevo servidor
- Puede provocar errores o perdida de datos

Al borrar los offsets, Debezium arranca limpio y realiza un snapshot completo del nuevo servidor.

### 1.6 Conservar datos de Kafka al cambiar

Si se quieren conservar los datos de Kafka entre cambios (por ejemplo para comparar datos de test y produccion), no es necesario borrar el volumen de Kafka. Los topics se crean con nombres basados en el prefijo `informix` + nombre de tabla, asi que los datos del servidor anterior permanecen en Kafka.

Para hacer un cambio limpio que tambien borre Kafka:

```bash
docker compose down --volumes   # borra TODOS los volumenes (Kafka + Debezium)
cp .env.production .env
docker compose up -d
```

---

## 2. Gestion de volumenes Docker

### 2.1 Volumenes del stack

| Volumen | Contenido | Path en contenedor | Persistente |
|---------|-----------|-------------------|-------------|
| `kafka-data` | Datos de Kafka (topics, mensajes, metadatos) | `/var/kafka-logs` | Si |
| `debezium-data` | Offsets + schema history de Debezium | `/debezium/data` | Si |

> **Nota tecnica**: La imagen `apache/kafka:3.9.0` corre como `appuser` (uid 1000) por defecto, lo que causa `AccessDeniedException` al escribir en volumenes Docker (que se crean como root). Por eso Kafka se configura con `user: "0:0"` y `KAFKA_LOG_DIRS=/var/kafka-logs` en el `docker-compose.yml`.

### 2.2 Comandos utiles

```bash
# Ver volumenes
docker volume ls --filter name=informix-debezium

# Borrar solo offsets de Debezium (fuerza nuevo snapshot, Kafka conserva datos)
docker compose down
docker volume rm informix-debezium_debezium-data
docker compose up -d

# Borrar todo (snapshot desde cero + Kafka vacio)
docker compose down --volumes
docker compose up -d

# Ver espacio usado
docker system df -v | grep informix-debezium
```

### 2.3 Comportamiento segun comando de parada

| Comando | Kafka pierde datos? | Debezium repuebla? |
|---------|---------------------|---------------------|
| `docker compose stop` / `start` | No | No (continua) |
| `docker compose down` | No (volumen persistente) | No (continua) |
| `docker compose down` + borrar debezium-data | No | Si (nuevo snapshot) |
| `docker compose down --volumes` | Si | Si (todo desde cero) |

---

## 3. Monitorizacion

### 3.1 Logs de Debezium

```bash
# Logs en tiempo real
docker logs -f debezium-server

# Buscar errores
docker logs debezium-server 2>&1 | grep -i error

# Ver progreso del snapshot
docker logs debezium-server 2>&1 | grep -E 'Exported|Finished|step [0-9]|Snapshot completed|streaming'
```

### 3.2 Estado de Kafka

```bash
# Listar topics
docker exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# Ver mensajes por topic
docker exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --group temp-check \
  --reset-offsets --to-latest \
  --topic informix.informix.ctercero \
  --dry-run
```

### 3.3 Redpanda Console (UI)

Accesible en http://localhost:9080 — permite explorar topics, ver mensajes individuales y monitorizar el cluster Kafka.

---

## 4. Troubleshooting

### 4.1 Debezium no arranca o reinicia en bucle

```bash
# Ver estado del contenedor
docker ps -a | grep debezium

# Ver logs de error
docker logs debezium-server 2>&1 | tail -30
```

**Causa comun**: Kafka no esta listo. Debezium tiene `restart: on-failure` y reintentara automaticamente.

### 4.2 Error "syscdcv1 not found"

```
Database (syscdcv1) not found or no system permission.
```

La base de datos `syscdcv1` no esta instalada en el servidor Informix. Ver seccion "Cambios en el servidor de produccion" en `PRODUCCION_INFORMIX.md`.

### 4.3 Error "No space left on device"

```bash
# Liberar espacio Docker
docker system prune -a --volumes -f

# Reconstruir
docker compose down --volumes
docker compose up -d
```

### 4.4 Kafka con indices corruptos (InvalidOffsetException)

Ocurre si Kafka se queda sin disco. Solucion:

```bash
docker compose down --volumes   # elimina datos corruptos
docker compose up -d            # arranque limpio
```
