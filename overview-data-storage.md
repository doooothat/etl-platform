# Data Storage, Views, and Mart Layer Overview

This document explains how data storage, catalogs, persistent views, materialized views, and mart tables are organized in this local ETL/Lakehouse platform.

The short version:

- Use `iceberg` for Nessie-backed Lakehouse source tables.
- Use `iceberg_dev` for Nessie-backed development branch experiments.
- Use `hive` for reusable Trino logical views.
- Use `iceberg_hms` for Trino materialized views backed by Hive Metastore.
- Use CTAS Iceberg tables when Spark and Trino must share the same physical mart dataset.

---

## 1. Catalog Layout

Trino currently exposes these project-owned catalogs:

| Catalog | Connector | Metadata Backend | Storage | Primary Use |
| :--- | :--- | :--- | :--- | :--- |
| `iceberg` | Iceberg | Nessie REST catalog, `main` ref | MinIO | Main Lakehouse tables |
| `iceberg_dev` | Iceberg | Nessie REST catalog, `dev` ref | MinIO | Development branch/testing |
| `hive` | Hive | Hive Metastore | MinIO or metadata-only | Persistent Trino logical views |
| `iceberg_hms` | Iceberg | Hive Metastore | MinIO | Trino materialized views and HMS-backed Iceberg tests |

Built-in Trino catalogs such as `system`, `jmx`, `memory`, `tpch`, and `tpcds` may also appear.

Check catalogs:

```bash
kubectl exec -n trino deploy/trino -- trino --execute "SHOW CATALOGS"
```

Expected project catalogs:

```text
hive
iceberg
iceberg_dev
iceberg_hms
```

---

## 2. Layer Responsibilities

```text
Raw / Source Data
  iceberg.ecommerce.*
  Backed by Nessie main + MinIO.

Development Experiments
  iceberg_dev.*
  Backed by Nessie dev + MinIO.

Reusable SQL Layer
  hive.shared.*
  Trino persistent views stored in Hive Metastore.

Trino BI Acceleration
  iceberg_hms.mart.*
  Trino materialized views stored through Hive Metastore and MinIO.

Spark/Trino Shared Physical Mart
  iceberg.mart.*
  CTAS or managed Iceberg tables, refreshed by Airflow/Spark/Trino jobs.
```

Use this rule of thumb:

| Requirement | Recommended Layer |
| :--- | :--- |
| Need Nessie branch/versioning | `iceberg` or `iceberg_dev` |
| Need always-current reusable SQL | `hive.shared.*` persistent view |
| Need Trino/Superset physical query acceleration | `iceberg_hms.mart.*` materialized view |
| Need Spark and Trino to share physical results | `iceberg.mart.*` CTAS/managed Iceberg table |
| Need refresh orchestration | Airflow DAG |

---

## 3. Persistent Logical Views

Persistent views store SQL definitions only. They do not store query result data.

Use them when:

- The query is light enough to run on demand.
- The result should always reflect the latest source table state.
- Superset or Trino users need a reusable semantic SQL layer.
- You want a named query abstraction without creating physical data.

Recommended namespace:

```text
hive.shared.*
```

Example:

```sql
CREATE SCHEMA IF NOT EXISTS hive.shared;

CREATE OR REPLACE VIEW hive.shared.country_sales_view AS
SELECT
  c.country,
  count(*) AS order_count,
  sum(o.amount) AS total_sales
FROM iceberg.ecommerce.orders o
JOIN iceberg.ecommerce.customers c
  ON o.customer_id = c.customer_id
GROUP BY c.country;
```

Query:

```sql
SELECT *
FROM hive.shared.country_sales_view
ORDER BY total_sales DESC;
```

Behavior:

- The view name and SQL definition persist in Hive Metastore.
- Query results are not stored.
- Each read executes the underlying SQL against the source tables.
- Source table changes are visible on the next read.
- Heavy joins/aggregations still run every time.

Drop a view:

```sql
DROP VIEW IF EXISTS hive.shared.country_sales_view;
```

Operational note:

- Prefer dropping individual views.
- Keep shared schemas such as `hive.shared` for reuse.
- Spark should not be expected to understand Trino-created views with full compatibility.

---

## 4. Trino Materialized Views

Materialized views store both:

- the SQL definition
- the physical query result

In this project, Trino materialized views work in the HMS-backed Iceberg catalog:

```text
iceberg_hms.mart.*
```

They do not work in the Nessie REST-backed `iceberg` catalog. The tested failure was:

```text
createMaterializedView is not supported for Iceberg REST catalog
```

This means:

| Catalog | Trino Materialized View |
| :--- | :--- |
| `iceberg` | Not supported because it uses Iceberg REST/Nessie |
| `iceberg_dev` | Not supported because it uses Iceberg REST/Nessie |
| `iceberg_hms` | Supported after HMS S3A configuration |

### 4.1 Create A Materialized View

Create a schema:

```sql
CREATE SCHEMA IF NOT EXISTS iceberg_hms.mart
WITH (location = 's3a://iceberg-data/hms-mart/');
```

Create a materialized view:

```sql
CREATE MATERIALIZED VIEW iceberg_hms.mart.country_sales_mv
WITH (format = 'PARQUET') AS
SELECT
  c.country,
  count(*) AS order_count,
  sum(o.amount) AS total_sales
FROM iceberg.ecommerce.orders o
JOIN iceberg.ecommerce.customers c
  ON o.customer_id = c.customer_id
GROUP BY c.country;
```

Refresh it:

```sql
REFRESH MATERIALIZED VIEW iceberg_hms.mart.country_sales_mv;
```

Query it:

```sql
SELECT *
FROM iceberg_hms.mart.country_sales_mv
ORDER BY total_sales DESC;
```

Inspect definition:

```sql
SHOW CREATE MATERIALIZED VIEW iceberg_hms.mart.country_sales_mv;
```

Drop it:

```sql
DROP MATERIALIZED VIEW IF EXISTS iceberg_hms.mart.country_sales_mv;
```

### 4.2 Runtime Behavior

Tested behavior:

- `CREATE MATERIALIZED VIEW` succeeds in `iceberg_hms`.
- `REFRESH MATERIALIZED VIEW` creates physical Parquet and Iceberg metadata files in MinIO.
- Source table changes are not automatically reflected after a refresh.
- Another `REFRESH MATERIALIZED VIEW` is required to update the stored result.
- `SHOW CREATE MATERIALIZED VIEW` currently shows `WHEN STALE INLINE`.

Example observed object storage layout:

```text
iceberg-data/hms-mart/mv_hms_test_sales-.../data/*.parquet
iceberg-data/hms-mart/mv_hms_test_sales-.../metadata/*.metadata.json
iceberg-data/hms-mart/mv_hms_test_sales-.../metadata/snap-*.avro
```

### 4.3 When To Use

Use `iceberg_hms.mart.*` materialized views when:

- The consumer is Trino or Superset.
- Query latency matters.
- The source query is expensive.
- Refresh can be scheduled by Airflow.
- Nessie branch/versioning is not required for this derived object.

Do not use it when:

- Spark must read or manage the object.
- Nessie branch semantics are required.
- You need automatic refresh on every source change.
- You need guaranteed incremental refresh without further testing.

---

## 5. CTAS / Managed Iceberg Mart Tables

CTAS creates a normal physical Iceberg table from a query result.

Recommended namespace:

```text
iceberg.mart.*
```

Example:

```sql
CREATE SCHEMA IF NOT EXISTS iceberg.mart
WITH (location = 's3://iceberg-data/mart/');

CREATE OR REPLACE TABLE iceberg.mart.country_sales AS
SELECT
  c.country,
  count(*) AS order_count,
  sum(o.amount) AS total_sales
FROM iceberg.ecommerce.orders o
JOIN iceberg.ecommerce.customers c
  ON o.customer_id = c.customer_id
GROUP BY c.country;
```

Query from Trino:

```sql
SELECT *
FROM iceberg.mart.country_sales
ORDER BY total_sales DESC;
```

Query from Spark Thrift Server:

```bash
kubectl exec -n spark deploy/spark-thrift-server -- \
  /opt/spark/bin/beeline -u jdbc:hive2://localhost:10000 \
  -e "SELECT * FROM iceberg.mart.country_sales ORDER BY total_sales DESC"
```

Behavior:

- The result is stored as a normal Iceberg table.
- Trino can read it.
- Spark can read it when using the existing Nessie-backed `iceberg` Spark catalog.
- Source changes are not automatically reflected.
- Rerun `CREATE OR REPLACE TABLE AS SELECT` or use a managed refresh job to update it.
- Nessie tracks create/update commits for these Iceberg tables.

Use this pattern when:

- Spark and Trino both need stable access.
- Branch/versioning through Nessie matters.
- You prefer explicit orchestration over Trino MV semantics.
- You want a durable mart dataset rather than a Trino-specific acceleration object.

---

## 6. Spark Compatibility

Spark currently works best with the Nessie-backed `iceberg` catalog.

Confirmed:

- Spark can see and query `iceberg.mart.*` CTAS tables.
- Spark can see HMS objects under `mart` after `iceberg_hms` is added.

Important limitation:

- Spark does not understand Trino materialized view semantics.
- Spark currently fails to query the tested `iceberg_hms.mart.*` source table because Spark is not configured with an HMS-backed Iceberg catalog.
- Spark fails to query the Trino materialized view because the stored Trino view SQL/metadata is not Spark-compatible.

Practical guidance:

| Need | Use |
| :--- | :--- |
| Spark and Trino shared mart | `iceberg.mart.*` CTAS table |
| Trino/Superset-only acceleration | `iceberg_hms.mart.*` materialized view |
| Future Spark access to HMS-backed Iceberg tables | Add a Spark `iceberg_hms` catalog configuration |

Do not let Spark write directly to Trino MV storage locations. Treat those as Trino-managed internals.

---

## 7. Refresh Strategy

No layer refreshes itself automatically.

| Object Type | Refresh Model |
| :--- | :--- |
| `hive.shared.*` persistent view | No refresh; query runs live |
| `iceberg_hms.mart.*` materialized view | `REFRESH MATERIALIZED VIEW` |
| `iceberg.mart.*` CTAS table | `CREATE OR REPLACE TABLE AS SELECT`, `INSERT OVERWRITE`, or Spark job |

Recommended Airflow patterns:

```sql
-- Trino materialized view refresh
REFRESH MATERIALIZED VIEW iceberg_hms.mart.country_sales_mv;
```

```sql
-- CTAS mart refresh
CREATE OR REPLACE TABLE iceberg.mart.country_sales AS
SELECT
  c.country,
  count(*) AS order_count,
  sum(o.amount) AS total_sales
FROM iceberg.ecommerce.orders o
JOIN iceberg.ecommerce.customers c
  ON o.customer_id = c.customer_id
GROUP BY c.country;
```

Use materialized views for Trino/Superset acceleration.

Use CTAS tables for cross-engine mart datasets.

---

## 8. Operational Requirements

### 8.1 Hive Metastore

Hive Metastore is now used for:

- `hive` catalog persistent views
- `iceberg_hms` catalog metadata

It requires:

- PostgreSQL backing database
- PostgreSQL JDBC driver
- S3A jars for MinIO-backed HMS Iceberg paths
- `core-site.xml` and `hive-site.xml` with S3A settings

Relevant chart files:

```text
hive-metastore/templates/configmap.yaml
hive-metastore/templates/deployment.yaml
hive-metastore/values.yaml
```

### 8.2 Trino

Trino must mount all project catalog files:

```text
/etc/trino/catalog/iceberg.properties
/etc/trino/catalog/iceberg_dev.properties
/etc/trino/catalog/hive.properties
/etc/trino/catalog/iceberg_hms.properties
```

Relevant chart files:

```text
trino/templates/configmap.yaml
trino/templates/deployment.yaml
trino/values.yaml
```

### 8.3 MinIO

Expected buckets/paths:

```text
iceberg-data/ecommerce/
iceberg-data/mart/
iceberg-data/hms-mart/
iceberg-data/hive-warehouse/
```

Inspect:

```bash
kubectl exec -n minio deploy/minio -- sh -lc \
  'mc alias set local http://localhost:9000 admin password --quiet && mc ls --recursive local/iceberg-data | head -120'
```

### 8.4 Nessie

Nessie applies to:

```text
iceberg
iceberg_dev
```

Nessie does not apply to:

```text
hive
iceberg_hms
```

Check history:

```bash
kubectl exec -n nessie deploy/nessie -- \
  curl -s 'http://localhost:19120/api/v2/trees/main/history?maxRecords=10'
```

---

## 9. Decision Matrix

| Scenario | Recommended Object |
| :--- | :--- |
| Simple reusable business definition | `hive.shared.some_view` |
| BI dashboard query is slow and Trino-only | `iceberg_hms.mart.some_mv` |
| Derived result must be shared with Spark | `iceberg.mart.some_table` |
| Need Nessie branch workflows | `iceberg` or `iceberg_dev` tables |
| Need experimental isolated catalog branch | `iceberg_dev` |
| Need physical result with explicit refresh | `iceberg.mart.*` CTAS or `iceberg_hms.mart.*` MV |
| Need true Trino MV syntax | `iceberg_hms.mart.*` |
| Need Spark compatibility today | `iceberg.mart.*` |

---

## 10. Known Limitations

- Trino materialized views are not supported in the Nessie REST-backed `iceberg` catalog.
- `iceberg_hms` materialized views are not Nessie-versioned.
- Spark does not understand Trino materialized view metadata.
- Spark needs additional configuration before it can reliably read HMS-backed Iceberg tables from `iceberg_hms`.
- Materialized views require explicit refresh.
- CTAS mart tables require explicit recreate/overwrite/merge logic.
- Incremental refresh behavior for `iceberg_hms` materialized views has not been proven yet.

---

## 11. Recommended Naming

Persistent views:

```text
hive.shared.<business_view_name>
```

Trino materialized views:

```text
iceberg_hms.mart.<subject>_mv
```

Spark/Trino shared mart tables:

```text
iceberg.mart.<subject>
```

Development objects:

```text
iceberg_dev.<namespace>.<object>
```

Examples:

```text
hive.shared.country_sales_view
iceberg_hms.mart.country_sales_mv
iceberg.mart.country_sales
iceberg_dev.mart.country_sales_experiment
```

---

## 12. Quick Smoke Tests

Catalogs:

```bash
kubectl exec -n trino deploy/trino -- trino --execute "SHOW CATALOGS"
```

Persistent view:

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
CREATE SCHEMA IF NOT EXISTS hive.shared;
CREATE OR REPLACE VIEW hive.shared.customer_count_view AS
SELECT count(*) AS customer_count
FROM iceberg.ecommerce.customers;
SELECT * FROM hive.shared.customer_count_view;
"
```

Materialized view:

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

CTAS shared mart:

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

Spark read of CTAS mart:

```bash
kubectl exec -n spark deploy/spark-thrift-server -- \
  /opt/spark/bin/beeline -u jdbc:hive2://localhost:10000 \
  -e "SELECT * FROM iceberg.mart.customer_count"
```
