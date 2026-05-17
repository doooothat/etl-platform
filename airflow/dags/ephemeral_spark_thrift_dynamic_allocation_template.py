from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from airflow.utils.trigger_rule import TriggerRule


SPARK_NAMESPACE = "spark"
AIRFLOW_NAMESPACE = "airflow"
SPARK_IMAGE = "custom-spark:4.0.2-nessie"
KUBECTL_IMAGE = "bitnami/kubectl:1.33.9"

RESOURCE_NAME = "ests-{{ ts_nodash | lower }}"
JDBC_URL = (
    "jdbc:hive2://"
    f"{RESOURCE_NAME}.{SPARK_NAMESPACE}.svc.cluster.local:10000"
)
VIEW_SUFFIX = "{{ ts_nodash | lower }}"


default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "email_on_failure": False,
    "email_on_retry": False,
    "retries": 0,
    "retry_delay": timedelta(seconds=30),
}


def kubectl_task(task_id: str, script: str, trigger_rule: str = TriggerRule.ALL_SUCCESS):
    return KubernetesPodOperator(
        task_id=task_id,
        namespace=AIRFLOW_NAMESPACE,
        service_account_name="airflow-worker",
        image=KUBECTL_IMAGE,
        image_pull_policy="IfNotPresent",
        cmds=["bash", "-lc"],
        arguments=[script],
        get_logs=True,
        is_delete_operator_pod=True,
        startup_timeout_seconds=180,
        trigger_rule=trigger_rule,
    )


def spark_sql_task(task_id: str, sql: str):
    script = f"""
set -euo pipefail

cat >/tmp/query.sql <<'SQL'
!set maxwidth 200
!set outputformat table
{sql}
SQL

/opt/spark/bin/beeline -u "{JDBC_URL}" -f /tmp/query.sql
"""

    return KubernetesPodOperator(
        task_id=task_id,
        namespace=AIRFLOW_NAMESPACE,
        image=SPARK_IMAGE,
        image_pull_policy="IfNotPresent",
        cmds=["bash", "-lc"],
        arguments=[script],
        get_logs=True,
        is_delete_operator_pod=True,
        startup_timeout_seconds=180,
    )


create_runtime = f"""
set -euo pipefail

cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: {RESOURCE_NAME}
  namespace: {SPARK_NAMESPACE}
  labels:
    app: {RESOURCE_NAME}
    managed-by: airflow
    runtime-kind: ephemeral-spark-thrift
spec:
  type: ClusterIP
  ports:
    - name: thrift
      port: 10000
      targetPort: 10000
    - name: spark-ui
      port: 4040
      targetPort: 4040
    - name: driver-rpc
      port: 7078
      targetPort: 7078
    - name: block-manager
      port: 7079
      targetPort: 7079
  selector:
    app: {RESOURCE_NAME}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {RESOURCE_NAME}
  namespace: {SPARK_NAMESPACE}
  labels:
    app: {RESOURCE_NAME}
    managed-by: airflow
    runtime-kind: ephemeral-spark-thrift
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {RESOURCE_NAME}
  template:
    metadata:
      labels:
        app: {RESOURCE_NAME}
        managed-by: airflow
        runtime-kind: ephemeral-spark-thrift
    spec:
      serviceAccountName: spark-operator-sa
      initContainers:
        - name: setup-dirs
          image: busybox:1.37.0
          command: ["sh", "-c", "mkdir -p /tmp/ivy && chmod -R 777 /tmp"]
          volumeMounts:
            - name: tmp-vol
              mountPath: /tmp
      containers:
        - name: thrift-server
          image: {SPARK_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - /opt/spark/bin/spark-submit
          args:
            - --class
            - org.apache.spark.sql.hive.thriftserver.HiveThriftServer2
            - --name
            - "{RESOURCE_NAME}"
            - --master
            - k8s://https://kubernetes.default.svc
            - --deploy-mode
            - client
            - --packages
            - org.apache.iceberg:iceberg-spark-runtime-4.0_2.13:1.10.1,org.apache.iceberg:iceberg-aws-bundle:1.10.1,org.apache.hadoop:hadoop-aws:3.4.1
            - --conf
            - spark.jars.ivy=/tmp/ivy
            - --conf
            - spark.kubernetes.namespace={SPARK_NAMESPACE}
            - --conf
            - spark.kubernetes.container.image={SPARK_IMAGE}
            - --conf
            - spark.kubernetes.authenticate.driver.serviceAccountName=spark-operator-sa
            - --conf
            - spark.kubernetes.executor.deleteOnTermination=true
            - --conf
            - spark.kubernetes.executor.label.airflow-runtime={RESOURCE_NAME}
            - --conf
            - spark.kubernetes.executor.label.managed-by=airflow
            - --conf
            - spark.driver.bindAddress=0.0.0.0
            - --conf
            - spark.driver.host={RESOURCE_NAME}.{SPARK_NAMESPACE}.svc.cluster.local
            - --conf
            - spark.driver.port=7078
            - --conf
            - spark.blockManager.port=7079
            - --conf
            - spark.ui.port=4040
            - --conf
            - spark.dynamicAllocation.enabled=true
            - --conf
            - spark.dynamicAllocation.shuffleTracking.enabled=true
            - --conf
            - spark.dynamicAllocation.minExecutors=0
            - --conf
            - spark.dynamicAllocation.initialExecutors=0
            - --conf
            - spark.dynamicAllocation.maxExecutors=3
            - --conf
            - spark.executor.cores=1
            - --conf
            - spark.executor.memory=2g
            - --conf
            - spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions,org.projectnessie.spark.extensions.NessieSparkSessionExtensions
            - --conf
            - spark.sql.catalog.iceberg=org.apache.iceberg.spark.SparkCatalog
            - --conf
            - spark.sql.catalog.iceberg.uri=http://nessie.nessie.svc.cluster.local:19120/api/v1
            - --conf
            - spark.sql.catalog.iceberg.ref=main
            - --conf
            - spark.sql.catalog.iceberg.warehouse=s3://iceberg-data/
            - --conf
            - spark.sql.catalog.iceberg.catalog-impl=org.apache.iceberg.nessie.NessieCatalog
            - --conf
            - spark.sql.catalog.iceberg.io-impl=org.apache.iceberg.aws.s3.S3FileIO
            - --conf
            - spark.hadoop.fs.s3a.endpoint=http://minio.minio.svc.cluster.local:9000
            - --conf
            - spark.hadoop.fs.s3a.access.key=admin
            - --conf
            - spark.hadoop.fs.s3a.secret.key=password
            - --conf
            - spark.hadoop.fs.s3a.path.style.access=true
            - --conf
            - spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem
            - --conf
            - spark.hadoop.fs.s3a.aws.credentials.provider=org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider
            - --conf
            - spark.sql.catalog.iceberg.client.region=us-east-1
            - --conf
            - spark.sql.catalog.iceberg.s3.endpoint=http://minio.minio.svc.cluster.local:9000
            - --conf
            - spark.sql.catalog.iceberg.s3.path-style-access=true
            - --conf
            - spark.sql.catalog.iceberg.s3.access-key-id=admin
            - --conf
            - spark.sql.catalog.iceberg.s3.secret-access-key=password
            - --conf
            - spark.sql.catalog.iceberg.s3.region=us-east-1
            - --conf
            - spark.sql.catalogImplementation=hive
            - --conf
            - spark.sql.warehouse.dir=file:/tmp/hive/warehouse
            - --conf
            - spark.hadoop.hive.metastore.uris=thrift://hive-metastore.hive-metastore.svc.cluster.local:9083
            - --conf
            - hive.server2.thrift.port=10000
            - --conf
            - hive.server2.thrift.bind.host=0.0.0.0
            - spark-internal
          env:
            - name: SPARK_NO_DAEMONIZE
              value: "true"
            - name: AWS_REGION
              value: us-east-1
          ports:
            - containerPort: 10000
              name: thrift
            - containerPort: 4040
              name: spark-ui
            - containerPort: 7078
              name: driver-rpc
            - containerPort: 7079
              name: block-manager
          volumeMounts:
            - name: tmp-vol
              mountPath: /tmp
          readinessProbe:
            tcpSocket:
              port: 10000
            initialDelaySeconds: 20
            periodSeconds: 5
          livenessProbe:
            tcpSocket:
              port: 10000
            initialDelaySeconds: 60
            periodSeconds: 20
      volumes:
        - name: tmp-vol
          emptyDir: {{}}
YAML

kubectl rollout status deployment/{RESOURCE_NAME} -n {SPARK_NAMESPACE} --timeout=300s
"""


wait_runtime = f"""
set -euo pipefail

for i in $(seq 1 60); do
  if /opt/spark/bin/beeline -u "{JDBC_URL}" -e "SELECT 1" >/tmp/beeline.out 2>&1; then
    cat /tmp/beeline.out
    exit 0
  fi
  cat /tmp/beeline.out || true
  sleep 5
done

echo "Timed out waiting for {JDBC_URL}" >&2
exit 1
"""


cleanup_runtime = f"""
set -euo pipefail

kubectl delete deployment/{RESOURCE_NAME} -n {SPARK_NAMESPACE} --ignore-not-found=true
kubectl delete service/{RESOURCE_NAME} -n {SPARK_NAMESPACE} --ignore-not-found=true
kubectl delete pod -n {SPARK_NAMESPACE} -l airflow-runtime={RESOURCE_NAME} --ignore-not-found=true
"""


with DAG(
    dag_id="ephemeral_spark_thrift_dynamic_allocation_template",
    description=(
        "DAG-run-scoped Spark Thrift Server with Kubernetes dynamic executor "
        "allocation; SQL tasks share global_temp views inside that runtime."
    ),
    schedule=None,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    max_active_runs=1,
    default_args=default_args,
    tags=["spark", "thrift-server", "dynamic-allocation", "template"],
) as dag:
    start_spark_runtime = kubectl_task(
        task_id="start_spark_runtime",
        script=create_runtime,
    )

    wait_spark_runtime = spark_sql_task(
        task_id="wait_spark_runtime",
        sql="SELECT 1 AS ready;",
    )
    wait_spark_runtime.arguments = [wait_runtime]

    create_base_view = spark_sql_task(
        task_id="create_base_view",
        sql=f"""
CREATE OR REPLACE GLOBAL TEMPORARY VIEW gv_base_{VIEW_SUFFIX} AS
SELECT id, amount
FROM VALUES
  (1, 100),
  (2, 250),
  (3, 400)
AS t(id, amount);

CACHE TABLE global_temp.gv_base_{VIEW_SUFFIX};

SELECT count(*) AS base_rows
FROM global_temp.gv_base_{VIEW_SUFFIX};
""",
    )

    create_derived_view = spark_sql_task(
        task_id="create_derived_view",
        sql=f"""
CREATE OR REPLACE GLOBAL TEMPORARY VIEW gv_derived_{VIEW_SUFFIX} AS
SELECT id, amount * 1.1 AS amount_with_tax
FROM global_temp.gv_base_{VIEW_SUFFIX};

SELECT round(sum(amount_with_tax), 1) AS total_with_tax
FROM global_temp.gv_derived_{VIEW_SUFFIX};
""",
    )

    cleanup_spark_runtime = kubectl_task(
        task_id="cleanup_spark_runtime",
        script=cleanup_runtime,
        trigger_rule=TriggerRule.ALL_DONE,
    )

    (
        start_spark_runtime
        >> wait_spark_runtime
        >> create_base_view
        >> create_derived_view
        >> cleanup_spark_runtime
    )
