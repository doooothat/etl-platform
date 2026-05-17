from __future__ import annotations

import math
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

try:
    from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
except Exception:
    KubernetesPodOperator = None


SPARK_THRIFT_JDBC_URL = (
    "jdbc:hive2://spark-thrift-server.spark.svc.cluster.local:10000"
)

VIEW_SUFFIX = (
    "{{ run_id | replace(':', '_') | replace('+', '_') | "
    "replace('-', '_') | replace('.', '_') }}"
)

BASE_VIEW = f"gv_airflow_base_{VIEW_SUFFIX}"
DERIVED_VIEW = f"gv_airflow_derived_{VIEW_SUFFIX}"
CACHE_VIEW = f"gv_airflow_cache_{VIEW_SUFFIX}"


default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "email_on_failure": False,
    "email_on_retry": False,
    "retries": 1,
    "retry_delay": timedelta(seconds=20),
}


def spark_sql_task(task_id: str, sql: str):
    script = f"""
set -euo pipefail

cat >/tmp/query.sql <<'SQL'
!set maxwidth 200
!set outputformat table
{sql}
SQL

/opt/spark/bin/beeline -u "{SPARK_THRIFT_JDBC_URL}" -f /tmp/query.sql
"""

    if KubernetesPodOperator is None:
        return BashOperator(
            task_id=task_id,
            bash_command=(
                "echo 'KubernetesPodOperator provider is not installed in this "
                "Airflow image.' >&2; exit 1"
            ),
        )

    return KubernetesPodOperator(
        task_id=task_id,
        namespace="airflow",
        image="custom-spark:4.0.2-nessie",
        image_pull_policy="IfNotPresent",
        cmds=["bash", "-lc"],
        arguments=[script],
        get_logs=True,
        is_delete_operator_pod=True,
        startup_timeout_seconds=180,
    )


def build_internal_payload(**context):
    payload = [
        {"id": 1, "amount": 100},
        {"id": 2, "amount": 250},
        {"id": 3, "amount": 400},
    ]
    print(f"Built Airflow-local payload: {payload}")
    return payload


def transform_internal_payload(**context):
    payload = context["task_instance"].xcom_pull(task_ids="airflow_build_payload")
    transformed = [
        {"id": row["id"], "amount_with_tax": row["amount"] * 1.1}
        for row in payload
    ]
    print(f"Transformed Airflow-local payload: {transformed}")
    return transformed


def assert_internal_payload(**context):
    transformed = context["task_instance"].xcom_pull(
        task_ids="airflow_transform_payload"
    )
    total = sum(row["amount_with_tax"] for row in transformed)
    print(f"Airflow-local total: {total}")
    assert math.isclose(total, 825.0)


with DAG(
    dag_id="spark_global_temp_view_vs_airflow_internal_test",
    description=(
        "Compares Spark Thrift Server global temp view sharing with "
        "Airflow-native XCom handoff."
    ),
    schedule=None,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    max_active_runs=1,
    default_args=default_args,
    tags=["spark", "thrift-server", "global-temp-view", "xcom", "test"],
) as dag:
    thrift_create_base_view = spark_sql_task(
        task_id="thrift_create_base_view",
        sql=f"""
CREATE OR REPLACE GLOBAL TEMPORARY VIEW {BASE_VIEW} AS
SELECT 1 AS id, 100 AS amount
UNION ALL
SELECT 2 AS id, 250 AS amount
UNION ALL
SELECT 3 AS id, 400 AS amount;
""",
    )

    thrift_read_base_from_new_task = spark_sql_task(
        task_id="thrift_read_base_from_new_task",
        sql=f"""
SELECT count(*) AS row_count, sum(amount) AS amount_sum
FROM global_temp.{BASE_VIEW};
""",
    )

    thrift_create_derived_view = spark_sql_task(
        task_id="thrift_create_derived_view",
        sql=f"""
CREATE OR REPLACE GLOBAL TEMPORARY VIEW {DERIVED_VIEW} AS
SELECT id, amount * 1.1 AS amount_with_tax
FROM global_temp.{BASE_VIEW};
""",
    )

    thrift_cache_and_materialize = spark_sql_task(
        task_id="thrift_cache_and_materialize",
        sql=f"""
CREATE OR REPLACE GLOBAL TEMPORARY VIEW {CACHE_VIEW} AS
SELECT *
FROM global_temp.{DERIVED_VIEW};

CACHE TABLE global_temp.{CACHE_VIEW};

SELECT count(*) AS cached_row_count
FROM global_temp.{CACHE_VIEW};
""",
    )

    thrift_read_cached_from_new_task = spark_sql_task(
        task_id="thrift_read_cached_from_new_task",
        sql=f"""
SELECT round(sum(amount_with_tax), 1) AS total_with_tax
FROM global_temp.{CACHE_VIEW};
""",
    )

    thrift_cleanup = spark_sql_task(
        task_id="thrift_cleanup",
        sql=f"""
UNCACHE TABLE IF EXISTS global_temp.{CACHE_VIEW};
DROP VIEW IF EXISTS global_temp.{CACHE_VIEW};
DROP VIEW IF EXISTS global_temp.{DERIVED_VIEW};
DROP VIEW IF EXISTS global_temp.{BASE_VIEW};
""",
    )

    airflow_build_payload = PythonOperator(
        task_id="airflow_build_payload",
        python_callable=build_internal_payload,
    )

    airflow_transform_payload = PythonOperator(
        task_id="airflow_transform_payload",
        python_callable=transform_internal_payload,
    )

    airflow_assert_payload = PythonOperator(
        task_id="airflow_assert_payload",
        python_callable=assert_internal_payload,
    )

    (
        thrift_create_base_view
        >> thrift_read_base_from_new_task
        >> thrift_create_derived_view
        >> thrift_cache_and_materialize
        >> thrift_read_cached_from_new_task
        >> thrift_cleanup
    )

    airflow_build_payload >> airflow_transform_payload >> airflow_assert_payload
