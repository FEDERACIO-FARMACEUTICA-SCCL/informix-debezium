# Guia rapida: Configurar Informix para Debezium CDC

Acciones que debe ejecutar el DBA en el servidor Informix para que Debezium capture cambios en tiempo real.

> Para documentacion detallada, ver [REQUISITOS_INFORMIX_CDC.md](REQUISITOS_INFORMIX_CDC.md).
> Para pasos especificos de produccion, ver [PRODUCCION_INFORMIX.md](PRODUCCION_INFORMIX.md).

---

## Pre-requisitos

- Acceso SSH al servidor Informix como usuario `informix`
- La base de datos debe tener **logging habilitado** (`CREATE DATABASE ... WITH LOG`)
- Conocer: nombre de la BD, nombre del servidor Informix, usuario de conexion de Debezium

### Verificar logging

```sql
SELECT name, is_logging FROM sysmaster:sysdatabases WHERE name = '<DB_NAME>';
-- is_logging debe ser 1
```

---

## Acciones (ejecutar como usuario `informix`)

### 1. Configurar entorno

```bash
export INFORMIXDIR=/opt/ibm/informix
export PATH=$INFORMIXDIR/bin:$PATH
export INFORMIXSERVER=<nombre_servidor>
export ONCONFIG=onconfig.<nombre_servidor>
export LD_LIBRARY_PATH=$INFORMIXDIR/lib:$INFORMIXDIR/lib/esql:$LD_LIBRARY_PATH
```

### 2. Instalar syscdcv1

Solo una vez por servidor. Es la base de datos de infraestructura CDC.

```bash
dbaccess - $INFORMIXDIR/etc/syscdcv1.sql
```

### 3. Activar Full Row Logging en cada tabla

Ejecutar desde la base de datos `syscdcv1`:

```bash
echo 'DATABASE syscdcv1;
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("<DB_NAME>:informix.ctercero", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("<DB_NAME>:informix.cterdire", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("<DB_NAME>:informix.gproveed", 1);
CLOSE DATABASE;' | dbaccess -
```

Resultado esperado: `0` por cada funcion.

### 4. Dar permisos al usuario de Debezium

```bash
echo 'DATABASE syscdcv1;
GRANT CONNECT TO <DEBEZIUM_USER>;
CLOSE DATABASE;

DATABASE <DB_NAME>;
GRANT SELECT ON ctercero TO <DEBEZIUM_USER>;
GRANT SELECT ON gproveed TO <DEBEZIUM_USER>;
GRANT SELECT ON cterdire TO <DEBEZIUM_USER>;
CLOSE DATABASE;' | dbaccess -
```

> Si Debezium conecta como `informix`, los GRANT SELECT no son necesarios (es superusuario).

---

## Verificacion

```bash
# 1. syscdcv1 existe
echo "SELECT name FROM sysmaster:sysdatabases WHERE name = 'syscdcv1';" | dbaccess sysmaster -
# -> 1 registro

# 2. Full Row Logging activo por tabla
oncheck -pT <DB_NAME>:informix.ctercero 2>&1 | grep "Log Snooping"
oncheck -pT <DB_NAME>:informix.cterdire 2>&1 | grep "Log Snooping"
oncheck -pT <DB_NAME>:informix.gproveed 2>&1 | grep "Log Snooping"
# -> "TBLspace flagged for Log Snooping" por cada tabla

# 3. Conectividad (desde la maquina de Debezium)
nc -zv <INFORMIX_HOST> <INFORMIX_PORT>
# -> Connection succeeded
```

---

## Anadir nuevas tablas en el futuro

1. **En Informix** — activar Full Row Logging:

```sql
DATABASE syscdcv1;
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("<DB_NAME>:informix.nueva_tabla", 1);
CLOSE DATABASE;
```

2. **En Debezium** — anadir a `table.include.list` en `application.properties` y reiniciar.

---

## Notas importantes

- **syscdcv1** solo se instala una vez por servidor. No afecta a otras aplicaciones.
- **Full Row Logging** incrementa ligeramente el uso de logs logicos (cada UPDATE loguea la fila completa).
- **Ninguno de estos cambios requiere reiniciar el servidor Informix.**
- Si el usuario de Debezium no es `informix`, necesita CONNECT sobre `syscdcv1` y SELECT sobre las tablas.
- Sin `syscdcv1` + Full Row Logging, Debezium solo puede hacer snapshot (lectura inicial) pero no captura cambios en tiempo real.

---

## Checklist

```
[ ] Base de datos con logging (is_logging = 1)
[ ] syscdcv1 instalada
[ ] Full Row Logging en ctercero
[ ] Full Row Logging en cterdire
[ ] Full Row Logging en gproveed
[ ] Usuario Debezium con CONNECT en syscdcv1
[ ] Usuario Debezium con SELECT en las tablas
[ ] Puerto Informix accesible desde servidor Debezium
```
