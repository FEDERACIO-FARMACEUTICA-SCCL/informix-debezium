# Cambios requeridos en el servidor de produccion Informix

**Servidor**: `192.168.96.117`
**Puerto**: `9800`
**Base de datos**: `fedefarm`
**Usuario Debezium**: `rss_genesis`

---

## Estado actual

El snapshot inicial de Debezium ha completado correctamente, lo que confirma:
- La base de datos `fedefarm` tiene logging habilitado
- El usuario `rss_genesis` tiene permisos SELECT sobre las tablas
- La conectividad de red funciona

Sin embargo, al intentar pasar a modo **streaming** (captura en tiempo real), Debezium falla con:

```
Database (syscdcv1) not found or no system permission.
```

Esto significa que faltan los siguientes cambios en el servidor.

---

## Cambios necesarios

### 1. Instalar la base de datos `syscdcv1` (CRITICO)

La base de datos `syscdcv1` es el componente de infraestructura CDC de Informix. Sin ella, Debezium solo puede hacer snapshots pero no puede capturar cambios en tiempo real.

**Ejecutar como usuario `informix` en el servidor `192.168.96.117`:**

```bash
# Configurar variables de entorno (ajustar segun la instalacion real)
export INFORMIXDIR=/opt/ibm/informix       # o la ruta real de instalacion
export PATH=$INFORMIXDIR/bin:$PATH
export INFORMIXSERVER=<nombre_servidor>     # nombre del servidor Informix
export ONCONFIG=onconfig.<nombre_servidor>

# Instalar syscdcv1
dbaccess - $INFORMIXDIR/etc/syscdcv1.sql
```

**Verificacion:**

```sql
SELECT name FROM sysmaster:sysdatabases WHERE name = 'syscdcv1';
-- Debe devolver 1 registro
```

> **Nota**: Esta operacion solo se ejecuta una vez. No afecta al funcionamiento normal del servidor ni a otras aplicaciones.

---

### 2. Habilitar Full Row Logging en las tablas monitorizadas (CRITICO)

Sin Full Row Logging, la API CDC no captura los datos completos de las filas modificadas.

**Ejecutar como usuario `informix` en el servidor `192.168.96.117`:**

```bash
echo 'DATABASE syscdcv1;
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("fedefarm:informix.ctercero", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("fedefarm:informix.cterdire", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("fedefarm:informix.gproveed", 1);
CLOSE DATABASE;' | dbaccess -
```

**Resultado esperado**: `0` por cada funcion (exito).

**Verificacion:**

```bash
oncheck -pT fedefarm:informix.ctercero 2>&1 | grep -i "Log Snooping"
oncheck -pT fedefarm:informix.cterdire 2>&1 | grep -i "Log Snooping"
oncheck -pT fedefarm:informix.gproveed 2>&1 | grep -i "Log Snooping"
# Esperado: "TBLspace flagged for Log Snooping" por cada tabla
```

> **Impacto**: El Full Row Logging incrementa ligeramente el uso de logs logicos, ya que cada UPDATE logea la fila completa en lugar de solo los campos modificados. En tablas con baja frecuencia de escritura (como las de proveedores) el impacto es minimo.

---

### 3. Otorgar permiso CONNECT sobre syscdcv1 al usuario `rss_genesis` (CRITICO)

El usuario que usa Debezium para conectarse necesita acceso a `syscdcv1` para abrir sesiones CDC.

**Ejecutar como usuario `informix`:**

```sql
DATABASE syscdcv1;
GRANT CONNECT TO rss_genesis;
CLOSE DATABASE;
```

**Verificacion:**

```bash
echo "DATABASE syscdcv1; SELECT 1 FROM systables WHERE tabid = 1; CLOSE DATABASE;" | dbaccess - 2>&1
# Si ejecuta sin error de permisos, el GRANT es correcto
```

> **Alternativa**: Si se prefiere, Debezium puede conectarse directamente como usuario `informix` en lugar de `rss_genesis`. En ese caso, modificar `DB_USER=informix` y `DB_PASSWORD=<password_informix>` en el fichero `.env.production`.

---

## Checklist de verificacion

Ejecutar todo en el servidor `192.168.96.117` como usuario `informix`:

```
[ ] 1. syscdcv1 instalada:
      SELECT name FROM sysmaster:sysdatabases WHERE name = 'syscdcv1';
      -> Devuelve 1 registro

[ ] 2. Full Row Logging habilitado en ctercero:
      oncheck -pT fedefarm:informix.ctercero 2>&1 | grep "Log Snooping"
      -> "TBLspace flagged for Log Snooping"

[ ] 3. Full Row Logging habilitado en cterdire:
      oncheck -pT fedefarm:informix.cterdire 2>&1 | grep "Log Snooping"
      -> "TBLspace flagged for Log Snooping"

[ ] 4. Full Row Logging habilitado en gproveed:
      oncheck -pT fedefarm:informix.gproveed 2>&1 | grep "Log Snooping"
      -> "TBLspace flagged for Log Snooping"

[ ] 5. rss_genesis tiene CONNECT sobre syscdcv1:
      echo "DATABASE syscdcv1; SELECT 1 FROM systables WHERE tabid=1;" | dbaccess -
      -> Sin error de permisos
```

---

## Despues de aplicar los cambios

Una vez aplicados los 3 cambios en el servidor de produccion, reiniciar Debezium para que establezca la conexion CDC streaming:

```bash
cd ~/fedefarma/informix-debezium

# Opcion A: si el snapshot ya se hizo y los datos estan en Kafka, solo reiniciar
docker compose restart debezium

# Opcion B: si se quiere forzar un snapshot nuevo desde cero
docker compose down
docker volume rm informix-debezium_debezium-data
docker compose up -d
```

Monitorizar los logs para confirmar que entra en modo streaming:

```bash
docker logs -f debezium-server 2>&1 | grep -E 'Snapshot completed|Starting streaming|Connected metrics'
```

**Resultado esperado**:
```
Snapshot completed
Starting streaming
Connected metrics set to 'true'
```

Cuando aparezca "Starting streaming", Debezium esta capturando cambios en tiempo real.

---

## Resumen de impacto

| Cambio | Riesgo | Impacto en produccion |
|--------|--------|----------------------|
| Instalar `syscdcv1` | Bajo | Crea una BD de sistema nueva, no afecta a BDs existentes |
| Full Row Logging | Bajo | Incremento minimo en uso de logs logicos |
| GRANT CONNECT | Nulo | Solo afecta al usuario `rss_genesis` |

Ninguno de estos cambios requiere reiniciar el servidor Informix ni afecta a las aplicaciones existentes.
