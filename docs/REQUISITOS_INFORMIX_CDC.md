# Requisitos del Servidor Informix para Captura de Datos con Debezium

Documento de requisitos que el servidor IBM Informix debe cumplir para que Debezium Server pueda capturar cambios (CDC) en tiempo real mediante la Change Data Capture API.

---

## Tabla de contenidos

1. [Resumen](#1-resumen)
2. [Requisitos del servidor Informix](#2-requisitos-del-servidor-informix)
3. [Configuracion de la base de datos](#3-configuracion-de-la-base-de-datos)
4. [Instalacion de syscdcv1](#4-instalacion-de-syscdcv1)
5. [Habilitacion de Full Row Logging](#5-habilitacion-de-full-row-logging)
6. [Permisos y usuario de conexion](#6-permisos-y-usuario-de-conexion)
7. [Variables de entorno](#7-variables-de-entorno)
8. [Tablas monitorizadas](#8-tablas-monitorizadas)
9. [Consideraciones de logs logicos](#9-consideraciones-de-logs-logicos)
10. [Limitaciones de la API CDC](#10-limitaciones-de-la-api-cdc)
11. [Verificacion](#11-verificacion)
12. [Referencia rapida de comandos](#12-referencia-rapida-de-comandos)

---

## 1. Resumen

Debezium utiliza la **Informix Change Data Capture API** (Change Streams) para capturar en tiempo real las operaciones INSERT, UPDATE, DELETE y TRUNCATE ejecutadas sobre las tablas monitorizadas. La API lee las transacciones directamente de los **logs logicos** del servidor Informix.

Para que el pipeline funcione, el servidor Informix debe cumplir los siguientes requisitos:

| Requisito | Criticidad | Estado necesario |
|-----------|-----------|-----------------|
| Base de datos con logging habilitado | **Obligatorio** | `CREATE DATABASE ... WITH LOG` |
| Base de datos `syscdcv1` instalada | **Obligatorio** | Script `syscdcv1.sql` ejecutado |
| Full Row Logging habilitado por tabla | **Obligatorio** | `cdc_set_fullrowlogging()` = 1 por tabla |
| Usuario `informix` accesible | **Obligatorio** | Credenciales de conexion disponibles |
| Variable `DB_LOCALE` configurada | **Obligatorio** | Debe coincidir con el locale de la BD |
| Logs logicos dimensionados | **Recomendado** | Suficientes para el volumen de transacciones |
| Puerto 9088 accesible desde Debezium | **Obligatorio** | Conectividad de red verificada |

---

## 2. Requisitos del servidor Informix

### 2.1 Version de Informix

- **Minimo recomendado**: IBM Informix 12.10 o superior (la API CDC esta disponible desde 11.50).
- La imagen Docker de desarrollo utilizada en test es `icr.io/informix/informix-developer-database:latest`.
- Debezium 3.4.1.Final ha sido validado con esta imagen.

### 2.2 Tipo de servidor

- El servidor debe estar configurado como tipo **OLTP** (Online Transaction Processing).
- El modo CDC utiliza la API Change Streams, que lee directamente de los logs logicos. No requiere Enterprise Replication (ER) ni CDR.

### 2.3 Conectividad de red

El servicio Debezium necesita acceso de red al servidor Informix:

| Parametro | Valor tipico | Descripcion |
|-----------|-------------|-------------|
| Host | IP o hostname del servidor | Desde Docker: `host.docker.internal` (macOS) |
| Puerto | `9088` | Puerto SQLHOSTS de Informix |
| Protocolo | `onsoctcp` | TCP/IP sockets |

---

## 3. Configuracion de la base de datos

### 3.1 Logging habilitado (OBLIGATORIO)

La base de datos de la que se capturan cambios **debe tener logging habilitado**. Sin logging, la API CDC no puede funcionar.

**Para una base de datos nueva:**

```sql
CREATE DATABASE nombre_bd WITH LOG;
```

**Para verificar si una base de datos existente tiene logging:**

```sql
SELECT name, is_logging FROM sysmaster:sysdatabases WHERE name = 'nombre_bd';
```

Si `is_logging` = 1, el logging esta habilitado. Si es 0, es necesario habilitarlo. Habilitar logging en una base de datos existente sin logging requiere:

```sql
-- Desde una sesion dbaccess
ontape -s -L 0  -- Realizar level-0 backup primero
-- Luego el DBA puede convertir la BD a logged
```

> **Importante**: En produccion, la base de datos ya deberia tener logging habilitado. Consultar al DBA si hay dudas.

### 3.2 Locale de la base de datos

El locale de la base de datos debe ser conocido, ya que la variable `DB_LOCALE` del cliente debe coincidir exactamente.

**Para consultar el locale:**

```sql
SELECT dbs_collate FROM sysmaster:sysdatabases WHERE name = 'nombre_bd';
```

---

## 4. Instalacion de syscdcv1

La base de datos `syscdcv1` es el componente de infraestructura CDC de Informix. Contiene las funciones y tablas de sistema necesarias para gestionar las sesiones de captura de datos.

### 4.1 Verificar si ya esta instalada

```sql
SELECT name FROM sysmaster:sysdatabases WHERE name = 'syscdcv1';
```

Si devuelve un registro, ya esta instalada. Si no devuelve nada, hay que instalarla.

### 4.2 Instalar syscdcv1

La instalacion **debe ejecutarse como usuario `informix`** en el servidor:

```bash
# Conectar al servidor Informix (via SSH o docker exec)
# Configurar variables de entorno
export INFORMIXDIR=/opt/ibm/informix       # Ruta de instalacion de Informix
export PATH=$INFORMIXDIR/bin:$PATH
export INFORMIXSERVER=nombre_servidor      # Nombre del servidor (ej: informix)
export ONCONFIG=onconfig.nombre_servidor   # Fichero de configuracion (ej: onconfig.informix)
export LD_LIBRARY_PATH=$INFORMIXDIR/lib:$INFORMIXDIR/lib/esql:$LD_LIBRARY_PATH

# Ejecutar el script de instalacion
dbaccess - $INFORMIXDIR/etc/syscdcv1.sql
```

### 4.3 Verificar la instalacion

```bash
echo "DATABASE syscdcv1; SELECT COUNT(*) FROM systables; CLOSE DATABASE;" | dbaccess -
```

Si ejecuta sin errores, la instalacion es correcta.

> **Nota**: Esta operacion solo se realiza una vez por servidor. Si `syscdcv1` ya existe, no es necesario reinstalarla.

---

## 5. Habilitacion de Full Row Logging

Cada tabla de la que se quieran capturar cambios debe tener **Full Row Logging** habilitado de forma explicita. Sin esto, la API CDC no capturara los datos completos de las filas.

### 5.1 Funcion `cdc_set_fullrowlogging()`

**Sintaxis:**

```sql
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("database:owner.table_name", logging);
```

**Parametros:**

| Parametro | Tipo | Descripcion |
|-----------|------|-------------|
| `database:owner.table_name` | LVARCHAR | Nombre completo de la tabla: `basedatos:propietario.tabla` |
| `logging` | INTEGER | `1` = habilitar, `0` = deshabilitar |

**Retorno:**

| Valor | Significado |
|-------|-------------|
| `0` | Operacion exitosa |
| Otro entero | Codigo de error (consultar tabla `syscdcsess`) |

### 5.2 Requisitos de ejecucion

- **Debe ejecutarse como usuario `informix`**
- **Debe ejecutarse desde la base de datos `syscdcv1`** (no desde la base de datos de las tablas)
- Debe ejecutarse desde una aplicacion cliente (dbaccess, JDBC), no desde rutinas internas del servidor
- La variable `DB_LOCALE` debe estar configurada

### 5.3 Habilitar Full Row Logging en las tablas

```bash
echo 'DATABASE syscdcv1;
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("nombre_bd:informix.ctercero", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("nombre_bd:informix.cterdire", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("nombre_bd:informix.gproveed", 1);
CLOSE DATABASE;' | dbaccess -
```

> Reemplazar `nombre_bd` por el nombre real de la base de datos (ej: `testdb`, `fedefarm`, etc.).

Un resultado `0` por cada funcion indica exito.

### 5.4 Verificar el estado del Full Row Logging

Desde el servidor Informix, ejecutar:

```bash
oncheck -pT nombre_bd:informix.ctercero
```

Si el Full Row Logging esta activo, la salida incluira el texto: `TBLspace flagged for Log Snooping`.

### 5.5 Consideraciones

- El Full Row Logging **permanece activo** incluso cuando se cierra la sesion CDC. No se desactiva automaticamente.
- Para **deshabilitar** el Full Row Logging, primero hay que detener la captura con `cdc_endcapture()` y luego ejecutar `cdc_set_fullrowlogging("...", 0)`. Si no se para la captura antes, se obtiene el error `19816: Cannot perform this operation on a table defined for replication`.
- Debezium tiene la propiedad `cdc.stop.logging.on.close` (default `true`) que controla si Informix detiene el Full Row Logging cuando se cierra el streaming.

---

## 6. Permisos y usuario de conexion

### 6.1 Usuario requerido

La API CDC de Informix requiere el usuario **`informix`** para:

- Instalar la base de datos `syscdcv1`
- Ejecutar `cdc_set_fullrowlogging()`
- Conectarse desde Debezium para capturar cambios

### 6.2 Credenciales de conexion

Debezium necesita las siguientes credenciales para conectarse al servidor:

| Parametro | Descripcion |
|-----------|-------------|
| `database.hostname` | IP o hostname del servidor Informix |
| `database.port` | Puerto de conexion (tipicamente `9088`) |
| `database.user` | Usuario de conexion (`informix`) |
| `database.password` | Password del usuario |
| `database.dbname` | Nombre de la base de datos a monitorizar |

> **Seguridad**: Las credenciales se externalizan en un fichero `.env` y se inyectan como variables de entorno. Nunca se almacenan en texto plano en ficheros que se commitean a git.

### 6.3 Permisos sobre las tablas

El usuario de conexion debe tener permisos de **lectura (SELECT)** sobre todas las tablas incluidas en `table.include.list`. El usuario `informix` tiene estos permisos por defecto como superusuario del servidor.

---

## 7. Variables de entorno

Las siguientes variables de entorno deben estar configuradas en el **entorno del servidor Informix** cuando se ejecutan los comandos de configuracion CDC:

| Variable | Valor | Descripcion |
|----------|-------|-------------|
| `INFORMIXDIR` | `/opt/ibm/informix` (tipico) | Directorio de instalacion de Informix |
| `INFORMIXSERVER` | Nombre del servidor | Identificador del servidor en SQLHOSTS |
| `ONCONFIG` | `onconfig.<servidor>` | Fichero de configuracion del servidor |
| `PATH` | Incluir `$INFORMIXDIR/bin` | Para acceder a `dbaccess`, `oncheck`, etc. |
| `LD_LIBRARY_PATH` | `$INFORMIXDIR/lib:$INFORMIXDIR/lib/esql` | Librerias compartidas |
| `DB_LOCALE` | Locale de la BD (ej: `en_US.819`) | **Debe coincidir** con el locale de la base de datos |

---

## 8. Tablas monitorizadas

Las siguientes tablas estan configuradas para captura CDC en la configuracion actual de Debezium:

| Tabla | Identificador CDC | Descripcion |
|-------|-------------------|-------------|
| `ctercero` | `nombre_bd:informix.ctercero` | Terceros (proveedores, clientes, socios) |
| `cterdire` | `nombre_bd:informix.cterdire` | Direcciones de terceros |
| `gproveed` | `nombre_bd:informix.gproveed` | Datos de proveedor |

### 8.1 Anadir nuevas tablas al CDC

Para monitorizar una tabla adicional, se requieren **dos pasos**:

**Paso 1 — En el servidor Informix**: Habilitar Full Row Logging

```sql
DATABASE syscdcv1;
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("nombre_bd:informix.nueva_tabla", 1);
CLOSE DATABASE;
```

**Paso 2 — En la configuracion de Debezium**: Anadir la tabla a la lista

En `config/application.properties`:

```properties
debezium.source.table.include.list=nombre_bd.informix.ctercero,nombre_bd.informix.cterdire,nombre_bd.informix.gproveed,nombre_bd.informix.nueva_tabla
```

Reiniciar Debezium despues del cambio.

---

## 9. Consideraciones de logs logicos

La API CDC lee transacciones directamente de los **logs logicos** del servidor Informix. Si los logs logicos se reciclan antes de que Debezium los procese, se pueden perder eventos.

### 9.1 Parametros ONCONFIG relevantes

| Parametro | Descripcion | Recomendacion |
|-----------|-------------|---------------|
| `LOGFILES` | Numero de ficheros de log logico | Aumentar si los logs se reciclan demasiado rapido |
| `LOGSIZE` | Tamano de cada fichero de log (KB) | Ajustar segun volumen de transacciones |

**Formula orientativa para dimensionar:**

```
LOGSIZE = (conexiones_max * filas_max_por_tx * tamano_fila_bytes / 1024) / LOGFILES
```

### 9.2 Recomendaciones

- **Monitorizar el reciclaje de logs**: Si Debezium reporta errores de tipo "log no disponible", es indicativo de que los logs se reciclan demasiado rapido.
- **Full Row Logging incrementa el uso de logs**: Al habilitar Full Row Logging, cada UPDATE loguea la fila completa (no solo los campos cambiados), lo que aumenta el consumo de espacio en logs logicos.
- **Backup de logs**: Configurar backup continuo de logs logicos (`ontape -c`) para liberar espacio sin perder datos.
- Si Debezium se detiene durante un periodo prolongado y los logs se reciclan, sera necesario realizar un **nuevo snapshot** al reiniciar (Debezium detecta esto automaticamente con `snapshot.mode=when_needed`).

---

## 10. Limitaciones de la API CDC

Limitaciones importantes que el equipo de infraestructura y los DBA deben conocer:

| Limitacion | Detalle |
|-----------|---------|
| **No captura cambios de esquema** | La API CDC no detecta ALTER TABLE, CREATE INDEX, etc. |
| **No se puede alterar una tabla durante la captura** | Hay que detener Debezium antes de hacer DDL en tablas monitorizadas |
| **Captura secuencial** | La API procesa todas las transacciones secuencialmente |
| **No hay lectura retrospectiva** | La captura empieza desde el log logico actual; no se puede retroceder mas alla del ultimo log disponible |
| **Un session CDC por servidor** | Solo una sesion CDC puede estar activa por servidor Informix a la vez |

### 10.1 Procedimiento para cambios de esquema

Si es necesario ejecutar un ALTER TABLE o cualquier DDL en una tabla monitorizada:

1. **Detener** Debezium Server (`docker compose stop debezium`)
2. **Ejecutar** el DDL en Informix
3. **Borrar** los offsets de Debezium para forzar un nuevo snapshot:
   ```bash
   docker compose down debezium
   docker volume rm informix-debezium_debezium-data
   ```
4. **Reiniciar** Debezium (`docker compose up -d debezium`)

Debezium realizara un nuevo snapshot con el esquema actualizado.

---

## 11. Verificacion

Checklist para verificar que el servidor Informix esta correctamente configurado:

### 11.1 Checklist de pre-requisitos

```
[ ] 1. Base de datos creada con logging habilitado (WITH LOG)
[ ] 2. Base de datos syscdcv1 instalada y accesible
[ ] 3. Full Row Logging habilitado en TODAS las tablas a monitorizar
[ ] 4. Usuario informix con password conocido
[ ] 5. Puerto 9088 accesible desde la maquina donde corre Debezium
[ ] 6. DB_LOCALE configurado correctamente
[ ] 7. Logs logicos dimensionados adecuadamente
```

### 11.2 Comandos de verificacion

**Verificar que la BD tiene logging:**
```sql
SELECT name, is_logging FROM sysmaster:sysdatabases WHERE name = 'nombre_bd';
-- Esperado: is_logging = 1
```

**Verificar que syscdcv1 existe:**
```sql
SELECT name FROM sysmaster:sysdatabases WHERE name = 'syscdcv1';
-- Esperado: 1 registro
```

**Verificar Full Row Logging por tabla:**
```bash
oncheck -pT nombre_bd:informix.ctercero  2>&1 | grep -i "Log Snooping"
oncheck -pT nombre_bd:informix.cterdire  2>&1 | grep -i "Log Snooping"
oncheck -pT nombre_bd:informix.gproveed  2>&1 | grep -i "Log Snooping"
# Esperado: "TBLspace flagged for Log Snooping" por cada tabla
```

**Verificar conectividad desde Debezium:**
```bash
# Desde la maquina de Debezium
nc -zv <host_informix> 9088
# Esperado: Connection succeeded
```

---

## 12. Referencia rapida de comandos

### Configuracion inicial (ejecutar en el servidor Informix como usuario `informix`)

```bash
# 1. Configurar entorno
export INFORMIXDIR=/opt/ibm/informix
export PATH=$INFORMIXDIR/bin:$PATH
export INFORMIXSERVER=nombre_servidor
export ONCONFIG=onconfig.nombre_servidor
export LD_LIBRARY_PATH=$INFORMIXDIR/lib:$INFORMIXDIR/lib/esql:$LD_LIBRARY_PATH

# 2. Instalar syscdcv1 (solo la primera vez)
dbaccess - $INFORMIXDIR/etc/syscdcv1.sql

# 3. Habilitar Full Row Logging en las tablas
echo 'DATABASE syscdcv1;
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("nombre_bd:informix.ctercero", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("nombre_bd:informix.cterdire", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("nombre_bd:informix.gproveed", 1);
CLOSE DATABASE;' | dbaccess -

# 4. Verificar
oncheck -pT nombre_bd:informix.ctercero 2>&1 | grep "Log Snooping"
```

---

## Referencias

- [IBM Informix - Preparing to use the Change Data Capture API](https://www.ibm.com/docs/en/informix-servers/14.10?topic=api-preparing-use-change-data-capture)
- [IBM Informix - cdc_set_fullrowlogging() function](https://www.ibm.com/docs/en/informix-servers/14.10?topic=functions-cdc-set-fullrowlogging-function)
- [HCL Informix - The Change Data Capture API](https://help.hcl-software.com/hclinformix/1410/cdc/ids_cdc_057.html)
- [Debezium Informix Connector Documentation](https://debezium.io/documentation/reference/stable/connectors/informix.html)
