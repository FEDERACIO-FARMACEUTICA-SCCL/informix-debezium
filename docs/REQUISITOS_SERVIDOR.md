# Requisitos del servidor de produccion

Estimacion de recursos para ejecutar el stack completo (informix-debezium + informix-consumer) en un unico servidor.

> Basado en mediciones reales con el dataset de produccion (~81K ctercero + ~9K gproveed + ~139K cterdire).

---

## Resumen

| Recurso | Minimo | Recomendado |
|---------|--------|-------------|
| **RAM** | 4 GB | 4 GB |
| **CPU** | 2 vCPU | 2 vCPU |
| **Disco** | 15 GB SSD | 20 GB SSD |
| **SO** | Linux x86_64 con Docker | Ubuntu/Debian LTS |
| **Red** | Acceso al servidor Informix (ver `.env.production`) | |

---

## Desglose de memoria RAM

| Servicio | RAM medida | RAM recomendada | Notas |
|----------|----------:|----------------:|-------|
| Kafka (KRaft) | 952 MB | 1.5 GB | Componente mas pesado. Heap crece con topics/particiones. |
| Debezium Server | 438 MB | 512 MB | JVM estable tras completar el snapshot. |
| Consumer (Node.js) | 460 MB | 512 MB | Store en memoria con ~230K registros. Acotado por dataset. |
| Redpanda Console | 47 MB | 64 MB | UI de monitorizacion. Uso minimo. |
| Loki | 108 MB | 256 MB | Crece con volumen de logs ingestados. |
| Promtail | 28 MB | 64 MB | Agente de recoleccion de logs, ligero. |
| Grafana | 129 MB | 192 MB | Dashboards y queries sobre Loki. |
| SO + Docker daemon | — | 512 MB | Linux base, containerd, networking. |
| **Total** | **~2.5 GB** | **~3.6 GB** | |

4 GB deja margen para picos durante el snapshot inicial de Debezium y rebalanceos de Kafka.

---

## Desglose de CPU

| Servicio | CPU en reposo | CPU en pico | Cuando ocurre el pico |
|----------|-------------:|------------:|----------------------|
| Kafka | ~2% | ~15% | Durante snapshot (escritura masiva de topics) |
| Debezium Server | <1% | ~30% | Durante snapshot (~36 min en produccion) |
| Consumer | <1% | ~5% | Procesando rafagas de CDC events |
| Monitoring (Loki+Grafana+Promtail) | ~3% | ~5% | Queries de dashboards en Grafana |

2 vCPUs son suficientes. En reposo (streaming mode), el consumo total es <5%. Los picos solo ocurren durante el snapshot inicial o si se fuerza un re-snapshot.

---

## Desglose de disco

| Componente | Tamano actual | Crecimiento | Notas |
|------------|-------------:|-------------|-------|
| Imagenes Docker | 2.8 GB | Fijo | Se actualizan con nuevas versiones. |
| Kafka data | 1.55 GB | Incremental | Retencion infinita (`KAFKA_LOG_RETENTION_MS: -1`). |
| Debezium offsets | 108 KB | Despreciable | Solo offsets y schema history. |
| Loki logs | <1 MB | Segun retencion | Configurar `retention_period` en loki-config.yml. |
| Grafana | 23 MB | Despreciable | Dashboards y datasources. |

### Proyeccion de crecimiento de Kafka

El volumen de datos de Kafka depende de la frecuencia de cambios en las tablas monitorizadas:

- **Snapshot inicial**: ~1.5 GB (fijo, se genera una vez)
- **Streaming**: cada evento CDC ocupa ~1-2 KB
- Con ~100 cambios/dia: ~0.07 MB/dia → ~26 MB/ano
- Con ~1000 cambios/dia: ~0.7 MB/dia → ~256 MB/ano

20 GB de disco son suficientes para varios anos de operacion.

---

## Requisitos de red

| Conexion | Protocolo | Puerto | Direccion |
|----------|-----------|--------|-----------|
| Servidor Informix | TCP (DRDA) | Ver `.env.production` | Servidor → Informix |
| Kafka (interno) | TCP | 29092 | Solo entre contenedores |
| Debezium health | HTTP | 8080 | Solo localhost (127.0.0.1) |
| Redpanda Console | HTTP | 9080 | Solo localhost (127.0.0.1) |
| Grafana | HTTP | 3000 | Solo localhost (127.0.0.1) |
| Loki | HTTP | 3100 | Solo localhost (127.0.0.1) |

Todos los puertos estan vinculados a `127.0.0.1` excepto la conexion al servidor Informix. Si se necesita acceso remoto a Grafana o Redpanda Console, usar un tunel SSH o reverse proxy con autenticacion.

---

## Opciones de servidor

### VPS / Cloud VM

| Proveedor | Instancia | vCPU | RAM | Disco |
|-----------|-----------|------|-----|-------|
| AWS | t3.medium | 2 | 4 GB | 20 GB gp3 |
| Azure | B2s | 2 | 4 GB | 20 GB SSD |
| GCP | e2-medium | 2 | 4 GB | 20 GB SSD |
| Hetzner | CX22 | 2 | 4 GB | 40 GB SSD |
| OVH | B2-7 | 2 | 7 GB | 50 GB SSD |

### Servidor on-premise

Una VM con 2 vCPU, 4 GB RAM y 20 GB de disco en cualquier hipervisor (VMware, Proxmox, Hyper-V) es suficiente. Requisito: Docker Engine instalado.

---

## Notas

- **Informix test no se despliega** en el servidor de produccion. Solo se usa en desarrollo local.
- El **snapshot inicial** es la operacion mas intensiva (~36 min, pico de CPU y RAM). Tras completarse, el sistema entra en modo streaming con consumo minimo.
- Si la RAM es limitada, Kafka es el primer candidato para ajustar (`KAFKA_HEAP_OPTS`). El default de `apache/kafka:3.9.0` es 256 MB de heap pero reserva mas para page cache.
- Los datos de Kafka persisten en volumen Docker. Un `docker compose down` no los borra; solo `docker compose down --volumes` los elimina.
