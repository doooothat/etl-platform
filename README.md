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

This repository is intended to be reproducible on a matching local Mac environment:

- macOS on Apple Silicon or Intel
- OrbStack Kubernetes context, or an equivalent local Kubernetes cluster
- Docker daemon available to the current user
- `kubectl`, `helm`, `docker`, `curl`, and `jq`
- network access for image pulls, Helm repos, and Maven/JAR downloads
- 8GB+ RAM allocated to the local container/K8s runtime; 12GB is more comfortable for full startup

### 1. Configure `local.env` (Mandatory)
```bash
cp env.example local.env
# Edit local.env and set PROJECT_ROOT to your absolute project path
```

---

## ⚡ Quick Start

For a first-time clone on a matching Mac environment, run:

```bash
./manage-project.sh doctor
./manage-project.sh bootstrap
./manage-project.sh provision --yes --no-cache
```

`provision` performs the full local IaC flow: prerequisite checks, Helm repo setup, chart dependency setup, namespace creation, CRD bootstrap, custom Spark/Flink image rebuild, deploy, ordered start, and validation.

For an already-deployed local environment, use:

```bash
./manage-project.sh start
```

Check status:

```bash
./manage-project.sh status
```

Validate the running platform:

```bash
./manage-project.sh validate
```

Monitoring log flow:
Once started, you can see real-time logs landing in Kafka via **Kafka UI**: [http://localhost:9080](http://localhost:9080)

### Destructive Cold Start Test

Use this only on a project-dedicated local Kubernetes cluster:

```bash
./manage-project.sh integration-test --yes --no-cache
```

This removes project Helm releases, kubectl-managed project resources, project namespaces, and all Kubernetes PVs in the current cluster, then rebuilds local custom images and redeploys everything. If a project namespace is stuck in `Terminating`, the purge path force-finalizes it after the normal wait period. It does not modify git files or commits.

The command intentionally does not delete Kubernetes CRDs or Helm repo settings. `bootstrap` ensures required Spark, KEDA, and Prometheus CRDs exist for fresh local environments.

During ordered startup, MinIO credentials are copied into the Nessie namespace as `minio-creds` after the `iceberg-data` bucket is created. This keeps Nessie startup reproducible after a full namespace/PV purge.

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
- **DAG-Scoped Spark SQL Runtime**: Airflow can create an ephemeral Spark Thrift Server per DAG run so multiple tasks share `global_temp` views without using the always-on shared Thrift Server.
- **Real-time Log Collection**: Vector collects all K8s logs and buffers them in **Apache Kafka 3.9 (KRaft)**.
- **Lightweight Streaming Persist**: Flink reads `k8s_logs` from Kafka and appends raw log events to `iceberg.logs.k8s_logs_bronze` for Trino/Superset queries.
- **FIFO Data Retention**: Logic-based cleanup (500MB / 2hr) to prevent local disk exhaustion.
- **Dynamic Path Injection**: The `manage-project.sh` dynamically injects local roots into container mounts.
- **No PVC Policy**: All temporary data is memory-backed or ephemeral for zero-residue development.
- **Query Logic Separation**: Flink SQL is kept in `flink/sql/*.sql` and injected as a ConfigMap at startup, so streaming logic can be reviewed separately from Kubernetes YAML.
- **Local IaC Bootstrap**: `manage-project.sh doctor`, `bootstrap`, `provision`, and `validate` make first-time setup reproducible for a third party on the same Mac/K8s toolchain.

### Version Consistency Notes

The repository now keeps an explicit version matrix in [`versions.yaml`](./versions.yaml). The currently validated Spark path is centered on Spark 4.0.2:

| Component | Expected Runtime |
| :--- | :--- |
| Spark runtime | `custom-spark:4.0.2-nessie` |
| Spark base image | `apache/spark:4.0.2` |
| Iceberg Spark runtime | `iceberg-spark-runtime-4.0_2.13:1.10.1` |
| Spark Operator pod image | `ghcr.io/kubeflow/spark-operator/controller:2.4.0` |

Explicitly aligned in repository manifests:

- Airflow PostgreSQL, Superset PostgreSQL, and Hive Metastore PostgreSQL client use the same PostgreSQL `18.3` image digest.
- Trino references are aligned to `trinodb/trino:480`.
- Kafka manifests are aligned around Kafka `3.9.0`; the legacy Bitnami values file is marked as non-authoritative.
- Kafka UI and the Airflow kubectl helper no longer use `latest`.
- Nessie REST catalog warehouse URIs use `s3://iceberg-data/`, and MinIO request signing is disabled on the Nessie side so Spark, Flink, and Trino use their explicit local credentials directly.
- Local custom images are part of the reproducible setup: `manage-project.sh` builds `custom-spark:4.0.2-nessie` and `custom-flink:1.20.3-iceberg` when they are missing.

Remaining items that are intentionally not forced into one image family:

- The running Spark binary reports `4.0.2`, but one completed SparkApplication driver carried mixed labels: `spark-version=4.0.0` and `version=4.0.2`.
- Airflow Redis remains on the official `redis:7.2-bookworm` image, while Superset Redis remains on the Bitnami Redis image required by its chart. Both are explicitly pinned instead of being forced into one image family.
- The Superset websocket component is disabled in local values; its community image default is also pinned by digest before anyone enables websocket async queries.

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

`./manage-project.sh start flink` cancels any already-running local Flink jobs and removes local `/tmp/flink-checkpoints` before resubmitting the SQL runner. This keeps local redeploys deterministic after wiping Nessie/MinIO state.

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

For DAGs that need task-level retries while sharing Spark temporary state, use a DAG-scoped Spark Thrift Server pattern:

```text
Airflow DAG run -> ephemeral Spark Thrift Server -> SQL task A/B/C -> cleanup
```

In that pattern, the Spark driver stays alive for the DAG run, `global_temp` views are shared between SQL tasks, and only Spark executors scale out dynamically. See the 2026-05-17 study note for the validated template and caveats.

---

## ✅ Verified Environment
- **OS**: macOS (M4/M3/M2/M1 & Intel)
- **Container / K8s**: [OrbStack](https://orbstack.dev/) (K3s engine recommended)
- **RAM**: 8GB+ allocated (Platform uses ~12GB peak during full processing)

---
> **Learn More**: See [overview.md](./overview.md) for detailed architecture diagrams and component roles. See [study/study-2026-05-15-hive-metastore-trino-view-store.md](./study/study-2026-05-15-hive-metastore-trino-view-store.md) for the Hive Metastore troubleshooting case study.
> See also [study/study-2026-05-17-airflow-dag-scoped-spark-thrift-server.md](./study/study-2026-05-17-airflow-dag-scoped-spark-thrift-server.md) for the Airflow DAG-scoped Spark Thrift Server validation.
