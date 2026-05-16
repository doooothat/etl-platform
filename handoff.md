# AI Agent Handoff

This document captures the current project state after the data storage/catalog/materialized-view integration session.

## Last Update

- **Timestamp**: 2026-05-16T22:15:00+09:00
- **Agent**: Codex
- **Status**: Full platform starts successfully. Trino now has four project catalogs: `iceberg`, `iceberg_dev`, `hive`, and `iceberg_hms`. Persistent Trino views work through `hive`; Trino materialized views work through the new HMS-backed `iceberg_hms` catalog.

---

## Work Completed

### 1. Full Platform Startup Verified

The platform was started with:

```bash
./manage-project.sh start
```

Final startup result:

```text
All services are up & Data is Ready
```

Verified:

```text
hive-metastore       1/1 Running
trino                1/1 Running
spark-thrift-server  1/1 Running
iceberg-nessie-restore SparkApplication COMPLETED
```

No non-running pods were present at final verification:

```bash
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

Result:

```text
No resources found
```

### 2. Trino Catalog Layout Expanded

Trino now exposes these project catalogs:

```text
hive
iceberg
iceberg_dev
iceberg_hms
```

Intended use:

| Catalog | Backing Service | Purpose |
| :--- | :--- | :--- |
| `iceberg` | Nessie REST catalog, `main` ref + MinIO | Main Lakehouse tables and Spark/Trino shared CTAS marts |
| `iceberg_dev` | Nessie REST catalog, `dev` ref + MinIO | Development branch/testing |
| `hive` | Hive Metastore | Persistent Trino logical views |
| `iceberg_hms` | Hive Metastore + MinIO | Trino materialized views |

Built-in catalogs also appear: `system`, `jmx`, `memory`, `tpch`, `tpcds`.

### 3. Nessie-backed Materialized View Limitation Verified

Attempting to create a materialized view in the Nessie-backed `iceberg` catalog failed:

```text
createMaterializedView is not supported for Iceberg REST catalog
```

Conclusion:

```text
iceberg.mart.* cannot use Trino materialized view syntax while it is backed by Nessie REST catalog.
```

Use `iceberg.mart.*` for CTAS/managed Iceberg mart tables instead.

### 4. HMS-backed Iceberg Catalog Added

Added a new Trino catalog:

```text
iceberg_hms
```

This is configured as:

```properties
connector.name=iceberg
iceberg.catalog.type=hive_metastore
hive.metastore.uri=thrift://hive-metastore.hive-metastore.svc.cluster.local:9083
```

Purpose:

```text
Trino/Superset materialized views and HMS-backed Iceberg experiments.
```

### 5. Hive Metastore S3A Support Added

Hive Metastore needed S3A support to create HMS-backed Iceberg schemas on MinIO.

Changes:

- Added `hive-metastore/templates/configmap.yaml`
- Mounted explicit `hive-site.xml` and `core-site.xml`
- Mounted `hadoop-aws.jar`
- Mounted `aws-java-sdk-bundle.jar`
- Added `HADOOP_CLASSPATH=/opt/hive/lib/*`
- Changed Hive warehouse to:

```text
s3a://iceberg-data/hive-warehouse
```

This fixed schema creation such as:

```sql
CREATE SCHEMA IF NOT EXISTS iceberg_hms.mart
WITH (location = 's3a://iceberg-data/hms-mart/');
```

### 6. Trino Materialized View Verified

Created HMS-backed source table:

```sql
CREATE TABLE iceberg_hms.mart.mv_hms_test_source (
  country varchar,
  amount integer
)
WITH (format = 'PARQUET');

INSERT INTO iceberg_hms.mart.mv_hms_test_source
VALUES ('KR', 100), ('KR', 200), ('US', 50);
```

Created materialized view:

```sql
CREATE MATERIALIZED VIEW iceberg_hms.mart.mv_hms_test_sales
WITH (format = 'PARQUET') AS
SELECT
  country,
  count(*) AS order_count,
  sum(amount) AS total_sales
FROM iceberg_hms.mart.mv_hms_test_source
GROUP BY country;
```

Refreshed:

```sql
REFRESH MATERIALIZED VIEW iceberg_hms.mart.mv_hms_test_sales;
```

Final verified result:

```text
KR  3  700
US  2   75
```

Materialized view files were confirmed in MinIO:

```text
iceberg-data/hms-mart/mv_hms_test_sales-.../data/*.parquet
iceberg-data/hms-mart/mv_hms_test_sales-.../metadata/*.metadata.json
iceberg-data/hms-mart/mv_hms_test_sales-.../metadata/snap-*.avro
```

### 7. Spark Compatibility Checked

Spark Thrift Server can see HMS metadata:

```sql
SHOW DATABASES;
SHOW TABLES IN mart;
```

Observed:

```text
mart.mv_hms_test_source
mart.mv_hms_test_sales
```

But current Spark configuration cannot query these HMS-backed Iceberg/Trino MV objects:

- `mart.mv_hms_test_source` fails because Spark is not configured with a matching HMS-backed Iceberg catalog.
- `mart.mv_hms_test_sales` fails because Spark does not understand Trino materialized view metadata/SQL.

Operational conclusion:

```text
Use iceberg.mart.* CTAS tables for Spark/Trino shared physical marts.
Use iceberg_hms.mart.* materialized views for Trino/Superset acceleration only.
```

### 8. Documentation Updated

Added:

- `overview-data-storage.md`
- `study/study-2026-05-16-todo-materialized-view-trino-iceberg-nessie.md`

Updated:

- `overview.md`
- `handoff.md`

`overview-data-storage.md` is now the main guide for catalog/storage/view/mart decisions.

---

## Current Recommended Data Patterns

| Need | Use |
| :--- | :--- |
| Source-of-truth Lakehouse tables | `iceberg.*` |
| Development branch experiments | `iceberg_dev.*` |
| Reusable always-current SQL | `hive.shared.*` persistent views |
| Trino/Superset materialized acceleration | `iceberg_hms.mart.*` materialized views |
| Spark/Trino shared physical mart | `iceberg.mart.*` CTAS tables |
| Refresh orchestration | Airflow DAG |

---

## Common Commands

### Check Catalogs

```bash
kubectl exec -n trino deploy/trino -- trino --execute "SHOW CATALOGS"
```

### Query Sample Data

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
SELECT 'customers' AS table_name, count(*) FROM iceberg.ecommerce.customers
UNION ALL
SELECT 'products', count(*) FROM iceberg.ecommerce.products
UNION ALL
SELECT 'orders', count(*) FROM iceberg.ecommerce.orders;
"
```

Expected:

```text
customers = 15
products  = 14
orders    = 20
```

### Create Persistent View

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
CREATE SCHEMA IF NOT EXISTS hive.shared;
CREATE OR REPLACE VIEW hive.shared.customer_count_view AS
SELECT count(*) AS customer_count
FROM iceberg.ecommerce.customers;
SELECT * FROM hive.shared.customer_count_view;
"
```

### Create Materialized View

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
CREATE SCHEMA IF NOT EXISTS iceberg_hms.mart
WITH (location = 's3a://iceberg-data/hms-mart/');

CREATE MATERIALIZED VIEW iceberg_hms.mart.customer_count_mv
WITH (format = 'PARQUET') AS
SELECT count(*) AS customer_count
FROM iceberg.ecommerce.customers;

REFRESH MATERIALIZED VIEW iceberg_hms.mart.customer_count_mv;
SELECT * FROM iceberg_hms.mart.customer_count_mv;
"
```

### Create Spark/Trino Shared CTAS Mart

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
CREATE SCHEMA IF NOT EXISTS iceberg.mart
WITH (location = 's3://iceberg-data/mart/');

CREATE OR REPLACE TABLE iceberg.mart.customer_count AS
SELECT count(*) AS customer_count
FROM iceberg.ecommerce.customers;

SELECT * FROM iceberg.mart.customer_count;
"
```

Spark read:

```bash
kubectl exec -n spark deploy/spark-thrift-server -- \
  /opt/spark/bin/beeline -u jdbc:hive2://localhost:10000 \
  -e "SELECT * FROM iceberg.mart.customer_count"
```

---

## Important Notes

1. `iceberg_hms` is not Nessie-versioned.
2. Trino materialized views are not supported in `iceberg` or `iceberg_dev` because those catalogs use Iceberg REST/Nessie.
3. Spark does not understand Trino materialized view metadata.
4. `iceberg_hms.mart.*` is currently a Trino/Superset acceleration layer.
5. `iceberg.mart.*` remains the safer pattern for Spark/Trino shared physical marts.
6. Materialized views require explicit `REFRESH MATERIALIZED VIEW`.
7. CTAS marts require explicit `CREATE OR REPLACE TABLE AS`, overwrite, merge, or Spark refresh logic.
8. Incremental refresh behavior for `iceberg_hms` materialized views has not been proven yet.
9. Airflow refresh DAGs are the natural next operational step.

---

## Current Test Artifacts

The following test objects may still exist:

```text
iceberg.mart.mv_test_source
iceberg.mart.ctas_test_sales
iceberg_hms.mart.mv_hms_test_source
iceberg_hms.mart.mv_hms_test_sales
```

They can be kept for continued testing or dropped manually.

---

## Next Session Suggestions

1. Add an Airflow DAG to refresh `iceberg_hms.mart.*` materialized views.
2. Add an Airflow DAG or Spark job pattern for `iceberg.mart.*` CTAS mart refresh.
3. Decide whether to configure Spark with a separate HMS-backed Iceberg catalog.
4. Test whether `iceberg_hms` MV refresh is incremental or full refresh for larger append-only tables.
5. Add Superset datasets for `hive.shared.*`, `iceberg_hms.mart.*`, and `iceberg.mart.*`.
6. Consider replacing runtime JDBC/S3A jar wiring with a custom Hive Metastore image for deterministic startup.
