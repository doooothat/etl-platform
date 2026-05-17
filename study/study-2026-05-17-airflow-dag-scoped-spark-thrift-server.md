# Airflow DAG-Scoped Spark Thrift Server Study

Date: 2026-05-17

## 1. Purpose

This note records the validation result for using Spark `global_temp` views across multiple Airflow tasks without relying on the always-on shared Spark Thrift Server.

The target behavior is:

- create one Spark SQL runtime for one Airflow DAG run;
- let multiple Airflow tasks connect to that same runtime;
- share `global_temp` views inside that runtime;
- dynamically scale only Spark executors;
- delete the runtime after the DAG run finishes.

This is different from the default Airflow Spark operator pattern, where each task usually submits a separate Spark application. Separate Spark applications cannot share Spark temporary or global temporary views.

## 2. Version Check

The first check was whether Spark and adjacent runtime versions are mixed across the repository and the live local cluster.

### 2.1 Spark Stack

| Area | Repository / Template | Live Cluster | Status |
| :--- | :--- | :--- | :--- |
| Spark runtime image | `custom-spark:4.0.2-nessie` | `custom-spark:4.0.2-nessie` | OK |
| Apache Spark base image | `apache/spark:4.0.2` | through custom image | OK |
| Spark binary | `apache/spark:4.0.2` | running Thrift Server reports Spark `4.0.2`, Scala `2.13.16`, Java `17.0.17` | OK |
| Spark application version | `sparkVersion: "4.0.2"` in `spark/init-data-job.yaml` | restore driver uses custom Spark image | OK |
| Iceberg Spark runtime | `iceberg-spark-runtime-4.0_2.13:1.10.1` | same in Thrift runtime templates | OK |
| Iceberg AWS bundle | `iceberg-aws-bundle:1.10.1` | same in Thrift runtime templates | OK |
| Hadoop AWS package | `hadoop-aws:3.4.1` in Thrift Server templates | same in Thrift runtime templates | OK |
| Nessie Spark extension jar | `nessie-spark-extensions-4.0_2.13-0.107.4.jar` | built into custom image name, not introspected in this check | Needs image-level confirmation if strict audit is required |

Spark itself is consistent around Spark 4.0.2, Scala 2.13 Iceberg runtime, and Iceberg 1.10.1.

### 2.2 Mismatches / Loose Tags Found

| Component | Repository Value | Live Cluster Value | Risk |
| :--- | :--- | :--- | :--- |
| Nessie server | `nessie/custom-values.yaml` says `0.107.4` | live pod is `ghcr.io/projectnessie/nessie:0.107.4` after redeploy | Aligned after the 2026-05-17 full redeploy. |
| Nessie warehouse/signing | `s3://iceberg-data/`, request signing disabled | live config map has `request-signing-enabled=false` | Aligned for local MinIO clients; Spark, Flink, and Trino use explicit credentials. |
| Spark Operator Helm metadata | local chart/custom values point to `2.4.0` | Helm release reports chart/app `2.4.0`, pods run `controller:2.4.0` after redeploy | Aligned after switching deployment to the local `./spark` chart. |
| SparkApplication labels | `sparkVersion: "4.0.2"` | completed restore driver has both `spark-version=4.0.0` and `version=4.0.2` labels | Actual Spark binary is 4.0.2; labels are inconsistent and should not be used as the source of truth until cleaned up. |
| Airflow Redis | chart default `redis:7.2-bookworm` | `redis:7.2-bookworm` | Pinned enough for local use, but differs from Superset Redis image family. |
| Superset Redis | pinned to Bitnami Redis digest | live pod was Bitnami Redis 8.4.0 | Explicitly pinned, but not unified with Airflow Redis because the two charts use different image families. |

Items fixed in repository manifests after this audit:

- Airflow PostgreSQL, Superset PostgreSQL, and Hive Metastore PostgreSQL client now use the same PostgreSQL `18.3` image digest.
- Kafka UI is pinned by digest.
- The Airflow kubectl helper image is pinned to `bitnami/kubectl:1.33.9`.
- `airflow/trino-rest.yaml` now references `trinodb/trino:480`.
- `kafka/custom-values.yaml` now references Kafka `3.9.0` and is marked as legacy/non-authoritative.

### 2.3 Current Component Matrix

| Component | Live Version / Image |
| :--- | :--- |
| Airflow | `apache/airflow:3.0.2` |
| Spark runtime | `custom-spark:4.0.2-nessie` |
| Spark Operator pod image | `ghcr.io/kubeflow/spark-operator/controller:2.4.0` |
| Trino | `trinodb/trino:480` |
| Nessie | `ghcr.io/projectnessie/nessie:0.107.4` |
| Hive Metastore | `apache/hive:4.0.0` |
| Flink | `custom-flink:1.20.3-iceberg` |
| Kafka | `apache/kafka:3.9.0` |
| Vector | `timberio/vector:0.34.1-distroless-libc` |
| MinIO | `quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z` |
| Superset | `apache/superset:5.0.0` |

## 3. Tested Airflow Pattern

The validated template is `airflow/dags/ephemeral_spark_thrift_dynamic_allocation_template.py`.

The DAG creates a per-run Spark Thrift Server deployment and service:

```text
start_spark_runtime
  -> wait_spark_runtime
  -> create_base_view
  -> create_derived_view
  -> cleanup_spark_runtime
```

The generated runtime name uses the DAG logical timestamp:

```text
ests-{{ ts_nodash | lower }}
```

Each SQL task connects to:

```text
jdbc:hive2://ests-<run-ts>.spark.svc.cluster.local:10000
```

That endpoint is not the existing shared `spark-thrift-server.spark.svc` service. It is a DAG-run-scoped service.

## 4. Global Temp View Behavior

Spark `GLOBAL TEMPORARY VIEW` objects are scoped to a Spark application. They are visible to multiple sessions inside the same Spark application under the `global_temp` database.

Therefore:

- Airflow task A and task B can share `global_temp` views only when both connect to the same Spark application.
- Separate `SparkSubmitOperator` or `SparkKubernetesOperator` tasks usually create separate Spark applications, so they do not share `global_temp`.
- A DAG-run-scoped Thrift Server works because the driver stays alive while the DAG tasks run.

The successful test created:

```sql
CREATE OR REPLACE GLOBAL TEMPORARY VIEW gv_base_20260517t052000 AS ...
CACHE TABLE global_temp.gv_base_20260517t052000;
```

Then a later task read it:

```sql
CREATE OR REPLACE GLOBAL TEMPORARY VIEW gv_derived_20260517t052000 AS
SELECT id, amount * 1.1 AS amount_with_tax
FROM global_temp.gv_base_20260517t052000;
```

The later task returned:

```text
total_with_tax = 825.0
```

## 5. Dynamic Executor Allocation

The final working settings are:

```text
spark.dynamicAllocation.enabled=true
spark.dynamicAllocation.shuffleTracking.enabled=true
spark.dynamicAllocation.minExecutors=0
spark.dynamicAllocation.initialExecutors=0
spark.dynamicAllocation.maxExecutors=3
spark.executor.cores=1
spark.executor.memory=2g
```

The driver / Thrift Server stays as one deployment replica. Only executors scale out.

This was confirmed by driver logs:

```text
Requesting 1 new executor because tasks are backlogged
Registered executor ... with ID 1
```

An earlier attempt with `spark.dynamicAllocation.initialExecutors=1` failed because executor startup raced the Thrift Server / driver scheduler startup:

```text
RpcEndpointNotFoundException:
Cannot find endpoint: spark://CoarseGrainedScheduler@...:7078
```

For this local template, starting with zero initial executors is safer.

## 6. Cleanup Behavior

The cleanup task deletes:

- the per-run Spark Thrift Server deployment;
- the per-run service;
- executor pods labeled with `airflow-runtime=<resource-name>`.

Post-test Kubernetes checks found no leftover resources for the tested run names:

```text
ests-20260517t050000
ests-20260517t052000
```

## 7. Conclusion

The pattern works for DAG-scoped temporary Spark SQL state:

- it does not use the always-on shared Spark Thrift Server;
- it isolates each DAG run with its own Spark application;
- it allows multiple Airflow tasks to share `global_temp` views;
- it supports executor-only dynamic scale-out;
- it cleans up its Spark resources at the end of the DAG.

The main operational caveat is that the driver / Thrift Server must stay alive for the whole DAG run. If the driver restarts, the temporary views and cached state are lost.

Operational note from the same local reset cycle: the Flink bridge must be resubmitted from clean local state after Nessie/MinIO are wiped. `./manage-project.sh start flink` now cancels existing Flink jobs, removes local `/tmp/flink-checkpoints`, and resubmits the SQL runner so the job does not restore stale Iceberg sink metadata.

Before expanding this into production-like templates, keep the repo-side version matrix and rendered Helm images in sync. The live Nessie and Spark Operator metadata mismatches from the initial audit were cleaned up by the 2026-05-17 redeploy.
