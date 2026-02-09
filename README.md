# Informix CDC con Debezium Server + Kafka

Pipeline de Change Data Capture (CDC) que captura cambios en tiempo real desde IBM Informix y los publica en Apache Kafka, con Redpanda Console como interfaz de visualización.

## Arquitectura

```
┌──────────────┐     CDC      ┌──────────────────┐           ┌─────────┐
│   Informix   │ ──────────── │  Debezium Server │ ────────► │  Kafka  │
│  (testdb)    │  Change      │  (Informix CDC)  │  Producer │ (KRaft) │
└──────────────┘  Streams     └──────────────────┘           └────┬────┘
   Puerto 9088                    Puerto 8080                     │
                                                                  │
                                                           ┌──────┴──────┐
                                                           │  Redpanda   │
                                                           │  Console    │
                                                           └─────────────┘
                                                            Puerto 9080
```

### Componentes

| Servicio | Imagen | Puerto | Descripción |
|----------|--------|--------|-------------|
| **Informix** | `icr.io/informix/informix-developer-database:latest` | 9088 | Base de datos Informix (instancia de test) |
| **Kafka** | `apache/kafka:3.9.0` | 9092 | Broker Kafka en modo KRaft (sin Zookeeper) |
| **Debezium Server** | Custom (basada en `quay.io/debezium/server:3.4.1.Final`) | 8080 | Conector CDC para Informix |
| **Redpanda Console** | `redpandadata/console:latest` | 9080 | UI para visualizar topics y mensajes de Kafka |

## Estructura del proyecto

```
informix-debezium/
├── docker-compose.yml              # Stack principal: Kafka + Debezium + Redpanda Console
├── Dockerfile                      # Imagen custom de Debezium Server con drivers Informix
├── .env                            # Variables de entorno con credenciales (excluido de git)
├── .env.example                    # Plantilla de .env sin secretos
├── config/
│   ├── application.properties      # Configuración de Debezium (usa env vars del .env)
│   └── application.properties.example  # Plantilla de configuración
├── informix-test/
│   ├── docker-compose.yml          # Instancia Informix de test (stack separado)
│   └── init.sql                    # Script de inicialización de la BD
├── SQL/
│   ├── ctercero_DDL.sql            # DDL tabla ctercero
│   ├── cterdire_DLL.sql            # DDL tabla cterdire
│   ├── ff_fcloud_tercero_DDL.sql   # DDL tabla ff_fcloud_tercero
│   ├── gproveed_DDL.sql            # DDL tabla gproveed
│   ├── fedefarm_informix_*.sql     # Datos reales (excluidos de git, contienen PII)
│   └── ...
└── README.md
```

## Requisitos previos

- Docker y Docker Compose
- Apple Silicon (M1/M2/M3): las imágenes se ejecutan con emulación `linux/amd64` (configurado en los compose)
- Puertos disponibles: 9088, 9092, 8080, 9080

## Guía de instalación paso a paso

### 1. Levantar la instancia de Informix

La instancia de Informix está en un stack separado para poder reutilizar el stack de Debezium con una base de datos real en el futuro.

```bash
cd informix-test
docker compose up -d
```

Esperar a que el contenedor esté healthy (puede tardar 1-2 minutos):

```bash
docker ps --filter name=informix-test
# Esperar hasta ver: STATUS = Up ... (healthy)
```

El script `init.sql` se ejecuta automáticamente y crea:
- La base de datos `testdb` con logging habilitado (`WITH LOG`, requisito para CDC)
- La tabla `customers` con datos de ejemplo

### 2. Configurar CDC en Informix

Acceder al contenedor de Informix:

```bash
docker exec -it informix-test bash
```

Dentro del contenedor, configurar las variables de entorno y ejecutar los comandos:

```bash
export INFORMIXDIR=/opt/ibm/informix
export PATH=$INFORMIXDIR/bin:$PATH
export INFORMIXSERVER=informix
export ONCONFIG=onconfig.informix
export LD_LIBRARY_PATH=$INFORMIXDIR/lib:$INFORMIXDIR/lib/esql:$LD_LIBRARY_PATH
```

#### 2.1 Instalar la base de datos syscdcv1

```bash
dbaccess - $INFORMIXDIR/etc/syscdcv1.sql
```

#### 2.2 Habilitar full row logging en las tablas

```bash
echo 'DATABASE syscdcv1;
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("testdb:informix.customers", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("testdb:informix.ctercero", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("testdb:informix.cterdire", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("testdb:informix.ff_fcloud_tercero", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("testdb:informix.gproveed", 1);
CLOSE DATABASE;' | dbaccess -
```

Un resultado `0` por cada función indica éxito.

### 3. Crear las tablas adicionales y cargar datos

Desde el host (fuera del contenedor), copiar y ejecutar los DDL:

```bash
# Copiar los DDL al contenedor
docker cp SQL/ctercero_DDL.sql informix-test:/tmp/
docker cp SQL/cterdire_DLL.sql informix-test:/tmp/
docker cp SQL/ff_fcloud_tercero_DDL.sql informix-test:/tmp/
docker cp SQL/gproveed_DDL.sql informix-test:/tmp/
```

Ejecutar los CREATE TABLE dentro del contenedor:

```bash
docker exec informix-test bash -c '
export INFORMIXDIR=/opt/ibm/informix
export PATH=$INFORMIXDIR/bin:$PATH
export INFORMIXSERVER=informix
export ONCONFIG=onconfig.informix
export LD_LIBRARY_PATH=$INFORMIXDIR/lib:$INFORMIXDIR/lib/esql:$LD_LIBRARY_PATH
echo "DATABASE testdb;" > /tmp/create_all.sql
cat /tmp/ctercero_DDL.sql >> /tmp/create_all.sql
cat /tmp/cterdire_DLL.sql >> /tmp/create_all.sql
cat /tmp/ff_fcloud_tercero_DDL.sql >> /tmp/create_all.sql
cat /tmp/gproveed_DDL.sql >> /tmp/create_all.sql
echo "CLOSE DATABASE;" >> /tmp/create_all.sql
dbaccess - /tmp/create_all.sql
'
```

> **Nota**: Los DDL originales pueden requerir ajustes de sintaxis para Informix:
> - Eliminar `(5)` de los `smallint(5)` y `(10)` de los `date(10)`
> - Cambiar `default current` por `default current year to second` en columnas `datetime`
> - En `cterdire`, corregir el formato de `default 0,0000000000` por `default 0.0000000000` en las columnas `gps_latitud` y `gps_longitud`

Cargar los datos INSERT:

```bash
# Copiar los archivos de datos al contenedor
docker cp SQL/fedefarm_informix_gproveed.sql informix-test:/tmp/insert_gproveed.sql
docker cp SQL/fedefarm_informix_cterdire.sql informix-test:/tmp/insert_cterdire.sql
docker cp SQL/fedefarm_informix_ff_fcloud_tercero.sql informix-test:/tmp/insert_ff_fcloud_tercero.sql

# ctercero necesita quitar comillas del nombre de tabla
sed 's/"informix\.ctercero"/informix.ctercero/g' SQL/fedefarm_informix_ctercero.sql | \
  docker exec -i informix-test tee /tmp/insert_ctercero.sql > /dev/null
```

Ejecutar los INSERTs (configurando el formato de fecha):

```bash
for table in gproveed cterdire ff_fcloud_tercero ctercero; do
  docker exec informix-test bash -c "
    export INFORMIXDIR=/opt/ibm/informix
    export PATH=\$INFORMIXDIR/bin:\$PATH
    export INFORMIXSERVER=informix
    export ONCONFIG=onconfig.informix
    export LD_LIBRARY_PATH=\$INFORMIXDIR/lib:\$INFORMIXDIR/lib/esql:\$LD_LIBRARY_PATH
    export DBDATE=Y4MD-
    export GL_DATETIME='%Y-%m-%d %H:%M:%S'
    echo 'DATABASE testdb;' > /tmp/run_${table}.sql
    cat /tmp/insert_${table}.sql >> /tmp/run_${table}.sql
    echo 'CLOSE DATABASE;' >> /tmp/run_${table}.sql
    dbaccess - /tmp/run_${table}.sql 2>&1 | tail -3
  "
  echo "--- $table completado ---"
done
```

### 4. Configurar credenciales

Copiar la plantilla de variables de entorno y ajustar los valores:

```bash
cd ..
cp .env.example .env
# Editar .env con las credenciales reales
```

El fichero `.env` contiene las credenciales de conexion a Informix (`DB_HOSTNAME`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`). Estas variables se inyectan automaticamente en `application.properties` via Quarkus.

> **Importante**: El fichero `.env` esta excluido de git. Nunca commitear credenciales.

### 5. Levantar el stack de Debezium

```bash
docker compose up -d --build
```

Esto levanta:
- **Kafka** en modo KRaft (sin Zookeeper)
- **Debezium Server** con los drivers de Informix
- **Redpanda Console** como UI de Kafka

Verificar que Debezium está funcionando:

```bash
docker logs -f debezium-server
```

Debezium realizará un snapshot inicial de las tablas configuradas y luego pasará a modo streaming para capturar cambios en tiempo real.

### 6. Verificar el funcionamiento

#### Comprobar topics creados en Kafka

```bash
docker exec kafka /opt/kafka/bin/kafka-topics.sh --list --bootstrap-server kafka:29092
```

Topics esperados:
```
informix
informix.informix.customers
informix.informix.ctercero
informix.informix.cterdire
informix.informix.ff_fcloud_tercero
informix.informix.gproveed
```

#### Ver mensajes en Redpanda Console

Abrir en el navegador: **http://localhost:9080**

Navegar a **Topics** y seleccionar cualquier topic para ver los mensajes CDC en formato JSON.

#### Probar CDC en vivo

Insertar un registro de prueba (desde DataGrip o desde el contenedor):

```bash
docker exec informix-test bash -c '
export INFORMIXDIR=/opt/ibm/informix
export PATH=$INFORMIXDIR/bin:$PATH
export INFORMIXSERVER=informix
export ONCONFIG=onconfig.informix
export LD_LIBRARY_PATH=$INFORMIXDIR/lib:$INFORMIXDIR/lib/esql:$LD_LIBRARY_PATH
echo "DATABASE testdb; INSERT INTO customers (name, email, city) VALUES (\"Test CDC\", \"test@test.com\", \"Girona\"); CLOSE DATABASE;" | dbaccess -
'
```

El mensaje aparecerá en el topic `informix.informix.customers` de Kafka en segundos.

## Tablas monitorizadas

| Tabla | Registros | Descripción |
|-------|-----------|-------------|
| `customers` | 3+ | Tabla de prueba con datos de ejemplo |
| `ctercero` | 10,991 | Terceros (socios, empresas, clientes) |
| `cterdire` | 7,300 | Direcciones de terceros |
| `ff_fcloud_tercero` | 3,430 | Datos FarmaCloud de terceros |
| `gproveed` | 4 | Proveedores |

## Configuración

### Debezium Server (`config/application.properties`)

Las credenciales de conexion se externalizan via variables de entorno en `.env`:

| Variable | Default (.env.example) | Descripcion |
|----------|----------------------|-------------|
| `DB_HOSTNAME` | `host.docker.internal` | Host de Informix |
| `DB_PORT` | `9088` | Puerto de Informix |
| `DB_USER` | `informix` | Usuario de conexion |
| `DB_PASSWORD` | `changeme` | Password (cambiar en .env) |
| `DB_NAME` | `testdb` | Base de datos a monitorizar |

Otras propiedades relevantes en `application.properties`:

| Propiedad | Valor | Descripcion |
|-----------|-------|-------------|
| `debezium.source.topic.prefix` | `informix` | Prefijo para los topics de Kafka |
| `debezium.source.snapshot.mode` | `initial` | Realiza snapshot inicial + streaming |

### Dockerfile - Drivers necesarios

La imagen base `quay.io/debezium/server:3.4.1.Final` incluye el conector Informix, pero necesita estos JARs adicionales:

| JAR | Versión | Motivo |
|-----|---------|--------|
| `jdbc` | 4.50.12 | Driver JDBC de IBM Informix |
| `ifx-changestream-client` | 1.1.3 | Cliente de la API Change Streams de Informix |
| `bson` | 3.8.0 | Dependencia del driver JDBC |

> **Importante**: Las versiones deben coincidir con las declaradas en el `pom.xml` de Debezium 3.4.1.Final. Usar versiones incorrectas causa `NoClassDefFoundError`.

## Conexion desde DataGrip

| Campo | Valor |
|-------|-------|
| DBMS | IBM Informix (seccion "Basic Support") |
| Host | `localhost` |
| Port | `9088` |
| User | `informix` |
| Password | (ver `.env`) |
| Database | `testdb` |
| URL JDBC | `jdbc:informix-sqli://localhost:9088/testdb:INFORMIXSERVER=informix` |

## Comandos útiles

```bash
# Ver estado de los contenedores
docker ps

# Ver logs de Debezium en tiempo real
docker logs -f debezium-server

# Contar mensajes en un topic
docker exec kafka /opt/kafka/bin/kafka-get-offsets.sh \
  --bootstrap-server kafka:29092 \
  --topic informix.informix.ctercero

# Reiniciar Debezium (tras cambiar configuración)
docker compose restart debezium

# Reiniciar Debezium con snapshot limpio (borrar offsets)
docker compose down debezium
docker volume rm informix-debezium_debezium-data
docker compose up -d debezium

# Parar todo
docker compose down                  # Stack Debezium + Kafka
cd informix-test && docker compose down  # Informix
```

## Notas para produccion

- Configurar las credenciales reales en `.env` (usar `.env.example` como plantilla)
- Ajustar `table.include.list` en `application.properties` a las tablas que se deseen monitorizar
- Considerar usar Kafka offset storage en lugar de file-based para alta disponibilidad
- La instancia de Informix de test (`informix-test/`) no es necesaria en produccion
- Los puertos estan vinculados a `127.0.0.1` (solo acceso local); para produccion considerar usar una red Docker interna sin exponer puertos
