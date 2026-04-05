# 🤝 AI Agent Handoff (Finalized Session)

This document contains the project status and a guide for the next operator at the time of session completion.

## 🕒 Last Update
- **Timestamp**: 2026-04-03T23:59:00+09:00
- **Agent**: Antigravity (Google Deepmind)
- **Status**: Full system shutdown (stop) test completed and force-stop logic enhanced. (Current state: All pods at Scale 0)

## 🛠️ Work Completed Today

### 1. Superset - Trino(Iceberg) Integration Resolved
- **Issue**: Superset could not query Iceberg catalog tables through Trino.
- **Resolution**:
  - Fixed `manage-project.sh` to point to the correct local chart path (`./trino`) instead of the official Helm repo.
  - Updated `iceberg.rest-catalog.uri` in `trino/templates/configmap.yaml` from `/api/v1/iceberg/main` to `/iceberg/main` to match Nessie 0.107.0 REST Catalog endpoint changes.
  - Successfully verified queries for `ecommerce.customers` table in Superset SQL Lab (15 rows rendered).

### 2. manage-project.sh Script Optimization & Enhancement
- **Full PVC Destruction Policy**: Modified `stop` command to unconditionally delete all existing PVCs and PVs to ensure environmental isolation and ephemerality.
- **scale_ns Bug Fix**: Resolved an issue where StatefulSets failed to scale down to 0 (removed `--timeout=5s` API wait condition).
- **Zombie Process Prevention (Airflow Redis Issue)**:
  - Addressed a scenario where `kubectl delete pod --force` removed pods from K8s but left "orphan" processes in the container runtime (OrbStack/Docker).
  - Integrated a "laser script" into the `stop` logic that uses `docker ps` to identify and physically exterminate containers at the Docker level (`docker rm -f`).
- **Prometheus Operator Reconciliation Bug Fix**:
  - Fixed a bug where Prometheus Operator resurrected the Prometheus server pod right before shutdown.
  - Improved the script to `patch` the K8s CRD (`prometheus.monitoring`) to `spec.replicas: 0` at the very beginning of the shutdown process to prevent resurrection.
- **Spark Operator Version Pinning**: Hardcoded `--version 2.3.0` for Spark Operator deployment to avoid bugs in version 2.4.0 that caused `CrashLoopBackOff`.

### 3. Monitoring Stack (Prometheus + Grafana) Implementation
- **Lightweight Local Deployment**: Redesigned `kube-prometheus-stack` for resource optimization (OrbStack RAM usage ~4GB).
  - Created `custom-values.yaml` in the `monitoring` directory.
  - Disabled AlertManager and NodeExporter; set Prometheus storage to 1-Day (In-Memory).
- **Port Mapping & Local Access**: Exposed Grafana via `LoadBalancer` on port `3000` instead of 80 ([http://localhost:3000](http://localhost:3000) | admin : admin).
- **Script Integration**: Integrated Grafana startup into Stage 6 of the `manage-project.sh` Deploy & Start logic.

## 📊 Current System Status

### Running Services (All Stopped - Scale: 0)
The system is currently in a **fully stopped state** via `./manage-project.sh stop`. All namespace workloads are at Scale 0, Persistent Volumes (PVC/PV) are cleared, and zombie containers have been exterminated. You can safely proceed with any tasks or run `./manage-project.sh start`.

### Infrastructure Characteristics
- **Data Ephemerality**: All DBs/Storage use `persistence.enabled: false` (ephemeral). PVCs are wiped by the management script.
- **Nessie Catalog**: `IN_MEMORY` mode (requires re-init on pod restart).
- **Airflow DAGs**: `hostPath` mount (survives teardown).
- **MinIO**: Standalone mode, `iceberg-data` bucket automatically created.

## 🔧 Operation Commands

```bash
# Check Status
./manage-project.sh status

# Full Start / Stop
./manage-project.sh stop   # Scale 0, Clear PVC/PV, Finalizer cleanup applied
./manage-project.sh start  # Dependency-ordered startup & migration

# Re-deploy Individual Component
./manage-project.sh deploy nessie
./manage-project.sh deploy spark-operator

# Full Re-installation
./manage-project.sh deploy          # Shows confirmation prompt
./init_data.sh                      # Data initialization (included in 'start')

# Shut down OrbStack
./manage-project.sh shutdown
```

## ⚠️ Known Issues (Fixed)
1. **Spark Operator CrashLoopBackOff**: Resolved by pinning the Helm release version to `v2.3.0`.
2. **Airflow Namespace Stuck in Terminating**: Resolved by applying a `finalizers: null` patch to Airflow-redis pods and PVCs during `manage-project.sh stop`.

## 📝 Next Session Suggestions
1. **Begin Pipeline Development**: All ETL baseline and monitoring components are ready! You can start developing ETL pipelines via Airflow DAGs.
2. **Superset Dashboard Planning**: Design dashboards in Superset using Iceberg table statistics processed by Trino.
3. **Unity Catalog OSS Evaluation**: Consider a POC for `Delta Lake 4.x + Unity Catalog OSS` as a modern alternative stack.

---
*This document was updated by Antigravity at the end of the session on 2026-04-03.*
