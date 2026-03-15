# ETL Platform

Local data lakehouse platform on OrbStack (K3s).

> **AI Tooling**: 이 프로젝트는 **Claude Code**(터미널)와 **Antigravity**(IDE)를 병행 사용합니다.
> - 상세 아키텍처 → `./overview.md`
> - 실전 트러블슈팅 패턴 → `~/.claude/projects/-Users-smylere-work-etl-platform/memory/MEMORY.md`
> - 인프라 운영 워크플로우 → `.agents/workflows/`

## Project Structure

```
etl-platform/
├── manage-project.sh        # Infra lifecycle management
├── init_data.sh             # Data initialization (post-deploy)
├── overview.md              # Architecture, connections, credentials
├── airflow/                 # Airflow Helm chart (3.0.2, KEDA autoscaling)
│   ├── custom-values.yaml
│   └── dags/                # DAGs (hostPath mounted, survives teardown)
├── spark/                   # Spark Operator Helm chart + Thrift Server
│   ├── custom-values.yaml
│   ├── spark-thrift-server.yaml  # Thrift Server deployment (non-Helm)
│   └── examples/            # SparkApplication YAMLs
├── minio/                   # MinIO Helm chart (standalone, ephemeral)
│   └── custom-values.yaml
├── nessie/                  # Nessie Helm chart (IN_MEMORY catalog)
│   └── custom-values.yaml
├── superset/                # Superset Helm chart
│   ├── custom-values.yaml
│   └── analytics-values.yaml  # Separate analytics PostgreSQL
└── trino/                   # Trino Helm chart
    └── values.yaml
```

## Key Commands

```bash
./manage-project.sh start      # Scale up (replicas=1)
./manage-project.sh stop       # Scale down (replicas=0)
./manage-project.sh status     # Check all services
./manage-project.sh deploy     # Safe deploy (helm upgrade --install)
./manage-project.sh teardown   # Remove all Helm releases
./manage-project.sh rebuild    # teardown → deploy → init_data.sh
```

## Services & Namespaces

| Service | Namespace | External Port |
|---------|-----------|---------------|
| KEDA | keda | - (autoscaling operator) |
| Airflow | airflow | 8080 |
| Spark Operator | spark | - |
| Spark Thrift Server | spark | 10000 (Thrift), 4040 (UI) |
| MinIO | minio | 9000 (API), 9001 (Console) |
| Nessie | nessie | - (ClusterIP 19120) |
| Trino | trino | 18080 |
| Superset | superset | 8088 |
| Analytics DB | analytics | 5433 |

## Architecture Notes

- All stores are **ephemeral** (no PVC persistence). Data is recreated via `init_data.sh`.
- Deploy uses **3-stage ordering**: infra (MinIO, Nessie, Analytics DB) → data (Spark, Trino) → apps (Airflow, Superset)
- Airflow 3.x uses `api-server` (not `webserver`). Pod label: `component=api-server`
- DAGs are hostPath mounted from `airflow/dags/` — they survive any teardown.
- Nessie catalog is IN_MEMORY; MinIO has no persistence. Both reset on pod restart.
- `feat/infra-lifecycle-management` branch has improved lifecycle commands (deploy, teardown, rebuild with health checks).
