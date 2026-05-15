# 🤝 AI Agent Handoff

This document captures the current project state and the next operator notes after the Hive Metastore + Trino view-store integration session.

## 🕒 Last Update
- **Timestamp**: 2026-05-15T23:55:00+09:00
- **Agent**: Codex
- **Status**: Hive Metastore is integrated and verified as a Trino view-store catalog. Existing Iceberg/Nessie/MinIO query flow remains healthy.

## 🛠️ Work Completed Today

### 1. Hive Metastore Chart Added
- Added a local Helm chart under `hive-metastore/`.
- Uses `apache/hive:4.0.0`.
- Uses Airflow PostgreSQL as the backing DB host with database name `metastore`.
- Adds an `init-metastore-db` initContainer to wait for PostgreSQL and create the `metastore` database if missing.
- Adds a `download-driver` initContainer to download PostgreSQL JDBC driver and mount it into `/opt/hive/lib/postgresql-jdbc.jar`.
- Uses `file:/tmp/hive/warehouse` as the Hive warehouse path because this metastore is intended as a Trino view metadata store, not a Hive managed-table storage layer.

### 2. Lifecycle Script Updated
- `manage-project.sh` now knows the `hive-metastore` Helm release and namespace.
- Added `ensure_hive_metastore_db()` to prepare the backing database before Hive Metastore starts.
- Full startup now includes Stage 2.5 for Hive Metastore after Nessie/Spark Operator and before Trino/Spark Thrift Server.
- `./manage-project.sh` with no arguments now prints usage instead of failing with `$1: unbound variable`.

### 3. Trino Hive Catalog Enabled
- Added `catalog-hive.properties` to Trino config.
- Mounted it as `/etc/trino/catalog/hive.properties`.
- Verified `SHOW CATALOGS` returns `hive`, `iceberg`, and `iceberg_dev`.
- Trino is deployed from local chart as `trinodb/trino:480`.

### 4. Spark Thrift Server Connected to Hive Metastore
- Spark Thrift Server now uses `spark.sql.catalogImplementation=hive`.
- It connects to `thrift://hive-metastore.hive-metastore.svc.cluster.local:9083`.
- Added `hadoop-aws:3.4.1` package to remove Spark-side S3A classpath issues.
- Warehouse path is `file:/tmp/hive/warehouse` to avoid requiring S3A jars inside the Hive Metastore server.

### 5. Documentation Added
- Added detailed case study:
  - `study/study-2026-05-15-hive-metastore-trino-view-store.md`
- Updated:
  - `README.md`
  - `overview.md`
  - `handoff.md`

## 📊 Verified Current System Status

### Core Runtime
```text
hive-metastore       1/1 Running
trino                1/1 Running
spark-thrift-server  1/1 Running
```

No non-running pods were present at final verification:

```bash
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

Result:

```text
No resources found
```

### Trino Catalogs
Verified:

```bash
kubectl exec -n trino deploy/trino -- trino --execute "SHOW CATALOGS"
```

Important catalogs:

```text
hive
iceberg
iceberg_dev
```

Built-in catalogs also appear: `system`, `jmx`, `memory`, `tpch`, `tpcds`.

### Iceberg Sample Data
Verified counts through Trino:

```text
iceberg.ecommerce.customers = 15
iceberg.ecommerce.products  = 14
iceberg.ecommerce.orders    = 20
```

### View Store Smoke Tests
- Spark Thrift Server -> Hive Metastore -> Trino read path was verified.
- Trino-created view path was verified:
  - `CREATE SCHEMA IF NOT EXISTS hive.shared`
  - `CREATE OR REPLACE VIEW hive.shared.trino_smoke_view ...`
  - `SELECT count(*) FROM hive.shared.trino_smoke_view`
  - `DROP VIEW hive.shared.trino_smoke_view`

The test view was removed. The test schema was also cleaned up through Spark beeline.

## 🔧 Common Commands

### Check Runtime
```bash
kubectl get pods -n hive-metastore
kubectl get pods -n trino
kubectl get pods -n spark -l app=spark-thrift-server
```

### Check Catalogs
```bash
kubectl exec -n trino deploy/trino -- trino --execute "SHOW CATALOGS"
```

### Query Iceberg Tables
```bash
kubectl exec -n trino deploy/trino -- trino --execute "
SELECT count(*) FROM iceberg.ecommerce.customers;
SELECT count(*) FROM iceberg.ecommerce.products;
SELECT count(*) FROM iceberg.ecommerce.orders;
"
```

### Create a Trino View
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

### Drop a Trino View
```bash
kubectl exec -n trino deploy/trino -- trino --execute "
DROP VIEW IF EXISTS hive.shared.customer_summary;
"
```

## ⚠️ Important Notes

1. **Use `iceberg` for physical Lakehouse tables.**
   `iceberg.ecommerce.*` is backed by Nessie REST catalog and MinIO.

2. **Use `hive` for reusable Trino views.**
   `hive.shared.*` is backed by Hive Metastore.

3. **Prefer dropping views, not shared schemas.**
   `DROP VIEW` works from Trino. `DROP SCHEMA` can fail with a file warehouse location error, so keep shared schemas such as `hive.shared` around.

4. **Hive Metastore currently uses Airflow PostgreSQL.**
   This is acceptable for local development. A dedicated PostgreSQL chart would be cleaner for a more production-like setup.

5. **PostgreSQL JDBC driver is downloaded at pod startup.**
   For more deterministic/offline deployments, build a custom Hive Metastore image with the JDBC driver baked in.

6. **Commit is intentionally left to the user.**
   Changes are not staged or committed.

## 📝 Next Session Suggestions

1. Add a Superset saved database / dataset workflow for `hive.shared.*` views.
2. Consider a dedicated Hive Metastore PostgreSQL subchart if the metastore becomes more than a local view store.
3. Consider baking PostgreSQL JDBC driver into a small custom Hive Metastore image.
4. Add a lightweight script or Make target for Trino view smoke tests.
