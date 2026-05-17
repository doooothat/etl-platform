# 🚀 Modern ETL Platform (Local Lakehouse)

This project provides a local development environment for a modern Data Lakehouse architecture combining **Airflow**, **Spark**, **Trino**, **Nessie**, **Iceberg**, **Hive Metastore**, **MinIO**, **Superset**, **Kafka**, and **Vector**.

---

## 🏗️ Architecture Overview
This platform simulates a real-world enterprise data stack including:
- **Batch ETL**: Airflow -> Spark -> Iceberg -> MinIO
- **Real-time Streaming**: Pod Logs -> Vector -> Kafka -> Flink -> Iceberg
- **Query & Analytics**: Trino -> Iceberg -> Superset
- **Shared SQL Views**: Trino -> Hive Metastore (`hive` catalog)
- **Monitoring**: Prometheus -> Grafana

---

## 🛠️ Prerequisites & Configuration
Before starting the platform, you **MUST** configure your local environment variables.

### 1. Configure `local.env` (Mandatory)
```bash
cp env.example local.env
# Edit local.env and set PROJECT_ROOT to your absolute project path
```

---

## ⚡ Quick Start

### 1. Start Support Services
```bash
./manage-project.sh start
```

### 2. Check Status
```bash
./manage-project.sh status
```

### 3. Monitoring Log Flow
Once started, you can see real-time logs landing in Kafka via **Kafka UI**: [http://localhost:9080](http://localhost:9080)

---

## 🎨 Core Components & URLs

| Component | Port | Local URL |
| :--- | :--- | :--- |
| **Airflow** (UI) | 8080 | [http://localhost:8080](http://localhost:8080) |
| **Superset** (BI) | 8088 | [http://localhost:8088](http://localhost:8088) |
| **Kafka UI** (Log) | 9080 | [http://localhost:9080](http://localhost:9080) |
| **Flink** (Streaming) | 8081 | [http://localhost:8081](http://localhost:8081) |
| **Trino** (Query) | 18080 | [http://localhost:18080](http://localhost:18080) |
| **Grafana** (Dash) | 3000 | [http://localhost:3000](http://localhost:3000) |
| **MinIO** (S3) | 9001 | [http://localhost:9001](http://localhost:9001) |
| **Hive Metastore** | 9083 | Internal only |

---

## 📝 Key Features
- **Iceberg Lakehouse Catalog**: Trino and Spark query Iceberg tables through Nessie REST catalog with data stored in MinIO.
- **Trino View Store**: Trino stores reusable SQL views in the `hive` catalog backed by Hive Metastore.
- **Real-time Log Collection**: Vector collects all K8s logs and buffers them in **Apache Kafka 3.9 (KRaft)**.
- **Lightweight Streaming Persist**: Flink reads `k8s_logs` from Kafka and appends raw log events to `iceberg.logs.k8s_logs_bronze` for Trino/Superset queries.
- **FIFO Data Retention**: Logic-based cleanup (500MB / 2hr) to prevent local disk exhaustion.
- **Dynamic Path Injection**: The `manage-project.sh` dynamically injects local roots into container mounts.
- **No PVC Policy**: All temporary data is memory-backed or ephemeral for zero-residue development.
- **Query Logic Separation**: Flink SQL is kept in `flink/sql/*.sql` and injected as a ConfigMap at startup, so streaming logic can be reviewed separately from Kubernetes YAML.

### Streaming Log Query

The local streaming bridge stores Kafka log events in an Iceberg bronze table. The active Flink SQL is managed in `flink/sql/k8s_logs_to_iceberg.sql`:

```sql
SELECT *
FROM iceberg.logs.k8s_logs_bronze
ORDER BY ingested_at DESC
LIMIT 100;
```

Apply SQL changes by editing the SQL file and restarting the local Flink bridge:

```bash
./manage-project.sh start flink
```

The local Flink deployment intentionally uses no PVC. JobManager/TaskManager state is ephemeral, and the pipeline starts from new Kafka messages after restart. For production, keep the same logical flow but move checkpoint/savepoint and warehouse storage to durable object storage.

---

## 🔎 Query & View Workflow

Use the Iceberg catalog for physical Lakehouse tables:

```sql
SELECT *
FROM iceberg.ecommerce.customers;
```

Create reusable Trino views in the Hive Metastore-backed catalog:

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
CREATE SCHEMA IF NOT EXISTS hive.shared;
CREATE OR REPLACE VIEW hive.shared.customer_summary AS
SELECT country, count(*) AS customer_count
FROM iceberg.ecommerce.customers
GROUP BY country;
SELECT * FROM hive.shared.customer_summary ORDER BY country;
"
```

Clean up views with `DROP VIEW`; keep shared schemas such as `hive.shared` around for reuse.

### Processing Ownership

This repository owns the local platform and a minimal reference streaming job. In a production-style workflow, keep business SQL and orchestration logic in a separate repository:

| Area | Suggested Home | Notes |
| :--- | :--- | :--- |
| Platform infra | `etl-platform` | Kubernetes, Helm, local startup scripts, base Flink image |
| Streaming transforms | `analytics-pipelines` / `etl-workflows` | Flink SQL jobs, validation, deployment metadata |
| Batch orchestration | `analytics-pipelines` / `etl-workflows` | Airflow DAGs, dbt models, Spark jobs |
| Ad hoc analysis | Trino/Superset/Jupyter | Query Iceberg directly, write only to `sandbox` or `tmp` schemas |

Recommended engine split:

```text
Flink: Kafka streaming, windowed/stateful processing, near-real-time Iceberg writes
Trino: Ad hoc SQL, BI, data exploration, shared views
Spark: Large backfills, batch ETL, heavy historical reprocessing
```

---

## ✅ Verified Environment
- **OS**: macOS (M4/M3/M2/M1 & Intel)
- **Container / K8s**: [OrbStack](https://orbstack.dev/) (K3s engine recommended)
- **RAM**: 8GB+ allocated (Platform uses ~12GB peak during full processing)

---
> **Learn More**: See [overview.md](./overview.md) for detailed architecture diagrams and component roles. See [study/study-2026-05-15-hive-metastore-trino-view-store.md](./study/study-2026-05-15-hive-metastore-trino-view-store.md) for the Hive Metastore troubleshooting case study.
