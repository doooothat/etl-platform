# ETL 플랫폼 구조/절차/연결/설정 (로컬 기준)

## 1) 구조 트리 (로컬 기준, 핵심 리소스)

```
Cluster (Local Kubernetes: Orbstack)
├── Namespace: airflow
│   ├── Deployment: airflow-webserver
│   │   └── Pod: airflow-webserver-xxxxx
│   │       └── Container: airflow-webserver
│   ├── Deployment: airflow-scheduler
│   │   └── Pod: airflow-scheduler-xxxxx
│   │       └── Container: airflow-scheduler
│   ├── Deployment: airflow-worker
│   │   └── Pod: airflow-worker-xxxxx
│   │       └── Container: airflow-worker
│   └── Service: airflow-webserver (LoadBalancer: 8080)
│
├── Namespace: spark
│   ├── Deployment: spark-operator
│   │   └── Pod: spark-operator-xxxxx
│   │       └── Container: spark-operator-controller
│   └── SparkApplication: iceberg-nessie-restore
│       ├── Pod: spark-driver
│       │   └── Container: spark-driver
│       └── Pod: spark-executor
│           └── Container: spark-executor
│
├── Namespace: minio
│   ├── Deployment: minio
│   │   └── Pod: minio-0
│   │       └── Container: minio
│   ├── Service: minio (LoadBalancer: 9000)
│   └── Service: minio-console (LoadBalancer: 9001)
│
├── Namespace: nessie
│   ├── Deployment: nessie
│   │   └── Pod: nessie-xxxxx
│   │       └── Container: nessie
│   └── Service: nessie (ClusterIP: 19120)
│
├── Namespace: trino
│   ├── Deployment: trino-coordinator
│   │   └── Pod: trino-coordinator-xxxxx
│   │       └── Container: trino
│   └── Service: trino (LoadBalancer: 18080)
│
└── Namespace: superset
    ├── Deployment: superset
    │   └── Pod: superset-xxxxx
    │       └── Container: superset-webserver
    ├── Deployment: superset-postgresql (metadata DB)
    │   └── Pod: superset-postgresql-xxxxx
    │       └── Container: postgres
    ├── Deployment: postgres-analytics (analytics DB)
    │   └── Pod: postgres-analytics-xxxxx
    │       └── Container: postgres
    └── Service: superset (LoadBalancer: 8088)
```

## 2) 외부 접속 경로 (로컬, LoadBalancer 기준)

```
Airflow UI    → http://localhost:8080
Superset UI   → http://localhost:8088
Trino         → http://localhost:18080
MinIO API     → http://localhost:9000
MinIO Console → http://localhost:9001
```

## 3) 내부 연결 흐름 (정확한 DNS/포트 기준)

```
Airflow → Spark (SparkApplication 실행)

Spark → Nessie REST Catalog
  http://nessie.nessie.svc.cluster.local:19120/api/v1

Spark → MinIO S3
  http://minio.minio.svc.cluster.local:9000
  bucket: iceberg-data
  accessKey: admin
  secretKey: password

Trino → Nessie REST Catalog
  http://nessie.nessie.svc.cluster.local:19120/iceberg/main
  http://nessie.nessie.svc.cluster.local:19120/iceberg/dev

Trino → MinIO S3
  http://minio.minio.svc.cluster.local:9000
  accessKey: admin
  secretKey: password
  region: us-east-1

Superset → Metadata DB
  postgresql://superset:superset@superset-postgresql:5432/superset

Superset → Analytics DB
  postgresql://analytics:analytics@postgres-analytics-postgresql.analytics.svc.cluster.local:5433/analytics
```

## 4) 서비스/포트/크리덴셜 요약표

| 컴포넌트             | 내부 DNS                                                    | 포트  | 외부 접속                | 계정                      |
|----------------------|-------------------------------------------------------------|-------|--------------------------|---------------------------|
| Airflow Webserver    | `airflow-webserver.airflow.svc.cluster.local`               | 8080  | `http://localhost:8080`  | 기본 admin (Helm init)    |
| Analytics DB         | `postgres-analytics-postgresql.analytics.svc.cluster.local` | 5433  | 내부 전용                | `analytics` / `analytics` |
| MinIO API            | `minio.minio.svc.cluster.local`                             | 9000  | `http://localhost:9000`  | `admin` / `password`      |
| MinIO Console        | `minio-console.minio.svc.cluster.local`                     | 9001  | `http://localhost:9001`  | `admin` / `password`      |
| Nessie               | `nessie.nessie.svc.cluster.local`                           | 19120 | 내부 전용                | N/A                       |
| Superset             | `superset.superset.svc.cluster.local`                       | 8088  | `http://localhost:8088`  | `admin` / `admin`         |
| Superset Metadata DB | `superset-postgresql.superset.svc.cluster.local`            | 5432  | 내부 전용                | `superset` / `superset`   |
| Trino                | `trino.trino.svc.cluster.local`                             | 8080  | `http://localhost:18080` | N/A                       |
