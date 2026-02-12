# Cambios en el servidor Informix

Ejecutar como usuario `informix` en el servidor. Sustituir `<DB_NAME>` y `<DEBEZIUM_USER>` por los valores reales (ver `.env.production`).

---

## 0. Verificar que la base de datos tiene logging

```sql
SELECT name, is_logging FROM sysmaster:sysdatabases WHERE name = '<DB_NAME>';
```

`is_logging` debe ser `1`. Si es `0`:

- **BD nueva**: `CREATE DATABASE <DB_NAME> WITH LOG;`
- **BD existente sin logging**: ejecutar un level-0 backup (`ontape -s -L 0`) y luego convertirla con `ondblog unbuf <DB_NAME>` seguido de `ondblog buf <DB_NAME>`. Consultar al DBA.

---

## 1. Instalar syscdcv1

```bash
dbaccess - $INFORMIXDIR/etc/syscdcv1.sql
```

## 2. Activar Full Row Logging

```bash
echo 'DATABASE syscdcv1;
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("<DB_NAME>:informix.ctercero", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("<DB_NAME>:informix.cterdire", 1);
EXECUTE FUNCTION informix.cdc_set_fullrowlogging("<DB_NAME>:informix.gproveed", 1);
CLOSE DATABASE;' | dbaccess -
```

## 3. Permisos del usuario Debezium

```bash
echo 'DATABASE syscdcv1;
GRANT CONNECT TO <DEBEZIUM_USER>;
CLOSE DATABASE;' | dbaccess -
```

> Si Debezium conecta como `informix`, este paso no es necesario.

---

No requiere reinicio del servidor. No afecta a otras aplicaciones.
