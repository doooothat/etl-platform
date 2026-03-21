#!/bin/bash
set -euo pipefail

# ==============================================================================
# ETL Platform Management Script
# ==============================================================================
# Usage:
#   ./manage-project.sh start    - Ordered startup (respects dependency chain)
#   ./manage-project.sh stop     - Scale down all workloads (replicas=0)
#   ./manage-project.sh status   - Show current status of all workloads
#   ./manage-project.sh deploy   - Uninstall & Re-install all Helm charts
#   ./manage-project.sh shutdown - Stop the entire OrbStack engine
#
# Dependency order for 'start':
#   [Stage 0] KEDA
#   [Stage 1] MinIO
#     └─ bucket 'iceberg-data' creation
#   [Stage 2] Nessie (waits: MinIO + bucket)
#             Spark Operator (waits: MinIO)
#   [Stage 3] Trino (waits: Nessie ready)
#             Spark Thrift Server (waits: Spark Operator ready)
#   [Stage 4] Airflow (waits: airflow-postgresql, airflow-redis)
#             Superset (waits: superset-postgresql, superset-redis)
# ==============================================================================

# ── Colors ─────────────────────────────────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_BLUE='\033[1;34m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_CYAN='\033[1;36m'

log_stage() { echo -e "\n${C_BLUE}━━━ $* ━━━${C_RESET}"; }
log_ok()    { echo -e "  ${C_GREEN}✅ $*${C_RESET}"; }
log_wait()  { echo -e "  ${C_YELLOW}⏳ $*${C_RESET}"; }
log_info()  { echo -e "  ${C_CYAN}   $*${C_RESET}"; }
log_err()   { echo -e "  ${C_RED}❌ $*${C_RESET}"; }

# ── Configuration ──────────────────────────────────────────────────────────────
RELEASES=(
    "keda:keda:kedacore/keda:"
    "airflow:airflow:./airflow:./airflow/custom-values.yaml"
    "minio:minio:./minio/minio:./minio/custom-values.yaml"
    "nessie:nessie:./nessie/nessie:./nessie/custom-values.yaml"
    "spark-operator:spark:spark-operator/spark-operator:./spark/custom-values.yaml"
    "superset:superset:./superset/superset:./superset/custom-values.yaml"
    "trino:trino:trino/trino:./trino/values.yaml"
)

NAMESPACES=("keda" "airflow" "minio" "nessie" "spark" "superset" "trino")

# ── Helpers ────────────────────────────────────────────────────────────────────

# wait_deploy <namespace> <deployment-name> [timeout-seconds=120]
function wait_deploy() {
    local ns=$1 name=$2 timeout=${3:-120}
    log_wait "Waiting for deployment/$name in $ns (timeout: ${timeout}s)..."
    if kubectl wait --for=condition=available \
        --timeout="${timeout}s" \
        deployment/"$name" -n "$ns" 2>/dev/null; then
        log_ok "$name is ready."
    else
        log_err "$name did not become ready within ${timeout}s."
        log_info "Check: kubectl describe deployment/$name -n $ns"
        log_info "Continuing anyway — dependent services may fail."
    fi
}

# wait_statefulset <namespace> <sts-name> [timeout-seconds=180]
function wait_statefulset() {
    local ns=$1 name=$2 timeout=${3:-180}
    log_wait "Waiting for statefulset/$name in $ns (timeout: ${timeout}s)..."
    if kubectl rollout status statefulset/"$name" \
        -n "$ns" --timeout="${timeout}s" 2>/dev/null; then
        log_ok "$name is ready."
    else
        log_info "$name not ready within ${timeout}s — continuing anyway."
    fi
}

# scale_ns <namespace> <replicas> [deployments-only|statefulsets-only|both(default)]
function scale_ns() {
    local ns=$1 replicas=$2 mode=${3:-both}
    if ! kubectl get ns "$ns" >/dev/null 2>&1; then return 0; fi
    if [[ "$mode" == "both" || "$mode" == "deployments" ]]; then
        if [ "$(kubectl get deployments -n "$ns" 2>/dev/null | wc -l)" -gt 1 ]; then
            kubectl scale deployment --all --replicas="$replicas" -n "$ns" \
                --timeout=5s 2>/dev/null || true
        fi
    fi
    if [[ "$mode" == "both" || "$mode" == "statefulsets" ]]; then
        if [ "$(kubectl get statefulsets -n "$ns" 2>/dev/null | wc -l)" -gt 1 ]; then
            kubectl scale statefulset --all --replicas="$replicas" -n "$ns" \
                --timeout=5s 2>/dev/null || true
        fi
    fi
}

# ── Ordered Start ──────────────────────────────────────────────────────────────
function start_ordered() {
    echo -e "${C_BOLD}🚀 Starting ETL Platform (dependency-ordered)...${C_RESET}"
    echo -e "   $(date '+%Y-%m-%d %H:%M:%S')"

    # ────────────────────────────────────────────────────────────────
    # Stage 0: KEDA (autoscaler, no dependencies)
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 0: KEDA"
    scale_ns keda 1
    # KEDA는 보통 이미 running 상태 — 빠른 체크만
    kubectl wait --for=condition=available --timeout=60s \
        deployment/keda-operator -n keda 2>/dev/null \
        && log_ok "KEDA ready." || log_info "KEDA skipped (may already be running)."

    # ────────────────────────────────────────────────────────────────
    # Stage 1: MinIO (standalone, no upstream deps)
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 1: MinIO"
    scale_ns minio 1
    wait_deploy minio minio 120

    log_wait "Creating 'iceberg-data' bucket in MinIO..."
    BUCKET_OK=false
    for _retry in {1..12}; do
        if kubectl exec -n minio deploy/minio -- bash -c \
            "mc alias set local http://localhost:9000 admin password --quiet 2>/dev/null && \
             mc mb local/iceberg-data --ignore-existing 2>/dev/null" 2>/dev/null; then
            BUCKET_OK=true
            break
        fi
        log_info "  MinIO API not ready yet, retrying in 5s... (${_retry}/12)"
        sleep 5
    done
    if [ "$BUCKET_OK" = true ]; then
        log_ok "Bucket 'iceberg-data' is ready."
    else
        log_err "Bucket creation failed after retries — Nessie may not start correctly."
    fi

    # ────────────────────────────────────────────────────────────────
    # Stage 2: Nessie + Spark Operator (parallel, both need MinIO)
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 2: Nessie + Spark Operator (parallel)"

    scale_ns nessie 1
    scale_ns spark 1
    # spark-thrift-server는 Stage 3에서 기동해야 하므로 지금은 즉시 강제 종료(Scale 0)합니다.
    # (Nessie가 완전히 생성되기 전에 Thrift Server가 붙는 것을 방지)
    kubectl scale deployment spark-thrift-server --replicas=0 -n spark 2>/dev/null || true

    wait_deploy nessie nessie 180      # Nessie health-checks MinIO bucket
    wait_deploy spark spark-operator-controller 120
    wait_deploy spark spark-operator-webhook 120

    # ────────────────────────────────────────────────────────────────
    # Stage 3: Trino + Spark Thrift Server
    #   Trino needs Nessie (REST catalog endpoint)
    #   Spark Thrift Server needs Nessie & Spark Operator webhook
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 3: Trino + Spark Thrift Server"

    scale_ns trino 1
    # Trino ready 대기 (Nessie 연동 확인)
    wait_deploy trino trino 180

    # Trino와 Nessie가 완벽히 기동된 이후에 Thrift Server 기동
    log_wait "Starting Spark Thrift Server..."
    kubectl scale deployment spark-thrift-server --replicas=1 -n spark 2>/dev/null || true

    # Thrift Server는 best-effort로 대기
    kubectl rollout status deployment/spark-thrift-server -n spark \
        --timeout=120s 2>/dev/null \
        && log_ok "Spark Thrift Server is ready." \
        || log_info "Spark Thrift Server still starting (non-critical)."

    # ────────────────────────────────────────────────────────────────
    # Step 3.5: Iceberg Sample Data (Nessies & Spark Job)
    # ────────────────────────────────────────────────────────────────
    log_wait "Creating Iceberg sample data via Spark Job..."
    kubectl delete sparkapplication iceberg-nessie-restore -n spark --ignore-not-found --wait=false
    kubectl apply -f ./spark/examples/spark-iceberg-nessie.yaml >/dev/null
    
    # 데이터 적재가 완료될 때까지 잠시 대기 (비동기로 진행되지만 최소한의 확인)
    log_info "Sample data generation started in background (sparkapplication/iceberg-nessie-restore)."

    # ────────────────────────────────────────────────────────────────
    # Stage 4a: Airflow
    #   airflow-postgresql → airflow-redis → Migrations → Airflow apps
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 4a: Airflow (PostgreSQL → Redis → Migrations → Apps)"

    # DB 및 Redis 먼저 기동
    scale_ns airflow 1 statefulsets
    wait_statefulset airflow airflow-postgresql 120
    wait_statefulset airflow airflow-redis 120

    # 데이터베이스가 휘발성(ephemeral)인 경우 재기동 시 마이그레이션이 다시 필요할 수 있음
    log_wait "Preparing Airflow database (migrations & admin user)..."
    # 기존에 남아있는 Job이 있다면 삭제 (그래야 재생성되어 실행됨)
    kubectl delete job -n airflow airflow-run-airflow-migrations airflow-create-user 2>/dev/null || true
    
    # Helm upgrade를 통해 Job 재실행 (Wait-for-migrations Init container 대응)
    helm upgrade --install airflow ./airflow -n airflow -f ./airflow/custom-values.yaml --reuse-values >/dev/null

    log_wait "Waiting for Airflow migrations to complete..."
    kubectl wait --for=condition=complete --timeout=180s \
        job/airflow-run-airflow-migrations -n airflow 2>/dev/null \
        && log_ok "Airflow migrations completed." \
        || log_info "Migration job timed out — checking logs might be necessary."

    # 그 다음 Deployment들
    scale_ns airflow 1 deployments
    # api-server 확인
    kubectl wait --for=condition=available --timeout=120s \
        deployment/airflow-api-server -n airflow 2>/dev/null \
        && log_ok "Airflow API Server is ready." \
        || log_info "Airflow API Server still starting..."

    # ────────────────────────────────────────────────────────────────
    # Stage 4b: Superset
    #   superset-postgresql → superset-redis → DB Init → Superset apps
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 4b: Superset (PostgreSQL → Redis → App)"

    scale_ns superset 1 statefulsets
    wait_statefulset superset superset-postgresql 120
    wait_statefulset superset superset-redis-master 120

    # 데이터베이스 휘발성 대비 Superset 초기화 (마이그레이션 + 관리자 권한)
    log_wait "Preparing Superset database (migrations & admin user)..."
    kubectl delete job superset-init-db -n superset 2>/dev/null || true
    helm upgrade --install superset ./superset/superset -n superset -f ./superset/custom-values.yaml --reuse-values >/dev/null

    log_wait "Waiting for Superset init to complete..."
    kubectl wait --for=condition=complete --timeout=180s \
        job/superset-init-db -n superset 2>/dev/null \
        && log_ok "Superset init completed." \
        || log_info "Superset init timed out — checking logs might be necessary."

    scale_ns superset 1 deployments
    kubectl wait --for=condition=available --timeout=180s \
        deployment/superset -n superset 2>/dev/null \
        && log_ok "Superset is ready." \
        || log_info "Superset still starting..."

    # ────────────────────────────────────────────────────────────────
    # Stage 5: Data Initialization & Superset Link
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 5: Data Integration & Finalization"
    log_wait "Running init_data.sh to finalize database links and sample data..."
    ./init_data.sh >/dev/null && log_ok "Data initialization & Superset registration complete." \
        || log_err "Data initialization failed. Please run ./init_data.sh manually."

    # ────────────────────────────────────────────────────────────────
    # Done
    # ────────────────────────────────────────────────────────────────
    echo ""
    echo -e "${C_GREEN}${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}✨ All services are up & Data is Ready!${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""
    echo -e "  Airflow  → http://localhost:8080"
    echo -e "  Superset → http://localhost:8088  (admin / admin)"
    echo -e "  Trino    → http://localhost:18080"
    echo -e "  MinIO    → http://localhost:9001  (admin / password)"
}

# ── Stop (all at once, order doesn't matter) ───────────────────────────────────
function stop_all() {
    echo -e "${C_YELLOW}Scaling down all project workloads...${C_RESET}"
    for ns in "${NAMESPACES[@]}"; do
        if kubectl get ns "$ns" >/dev/null 2>&1; then
            echo "  --- $ns ---"
            scale_ns "$ns" 0
            kubectl delete sparkapplications --all -n "$ns" 2>/dev/null || true
        fi
    done
    echo -e "${C_YELLOW}All workloads scaled to 0.${C_RESET}"
}

# ── Deploy (Helm install/upgrade) ──────────────────────────────────────────────
function deploy_charts() {
    echo -e "${C_RED}WARNING: This will UNINSTALL and RE-INSTALL all project components.${C_RESET}"
    echo "This may result in data loss if volumes are not persistent. Continue? (y/n)"
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Deployment cancelled."
        return
    fi

    for entry in "${RELEASES[@]}"; do
        IFS=":" read -r release namespace chart values <<< "$entry"
        echo -e "\n${C_BLUE}>>> Processing $release in $namespace <<<${C_RESET}"

        echo "  Uninstalling $release..."
        helm uninstall "$release" -n "$namespace" 2>/dev/null \
            || echo "  $release not found, skipping uninstall."

        kubectl create namespace "$namespace" 2>/dev/null || true

        echo "  Installing $release using $chart..."
        if [[ "$chart" == *"spark-operator"* ]]; then
            helm upgrade --install "$release" "$chart" \
                -n "$namespace" -f "$values" --set webhook.enable=true
        else
            helm upgrade --install "$release" "$chart" \
                -n "$namespace" -f "$values"
        fi
    done

    echo -e "\n${C_BLUE}>>> Deploying Spark Thrift Server <<<${C_RESET}"
    kubectl delete -f ./spark/spark-thrift-server.yaml 2>/dev/null \
        || echo "  Spark Thrift Server not found, skipping delete."
    kubectl apply -f ./spark/spark-thrift-server.yaml

    echo -e "\n${C_GREEN}Deployment complete. Run './manage-project.sh start' to bring services up.${C_RESET}"
}

# ── Main ───────────────────────────────────────────────────────────────────────
case "$1" in
    start)
        start_ordered
        ;;
    stop)
        stop_all
        ;;
    status)
        for ns in "${NAMESPACES[@]}"; do
            if kubectl get ns "$ns" >/dev/null 2>&1; then
                echo -e "\n${C_BLUE}Namespace: $ns${C_RESET}"
                kubectl get deployments,statefulsets,pods -n "$ns" 2>/dev/null
            fi
        done
        ;;
    deploy)
        deploy_charts
        ;;
    shutdown)
        echo "Are you sure you want to stop the entire OrbStack engine? (y/n)"
        read -r confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            orbctl stop
        else
            echo "Shutdown cancelled."
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|status|deploy|shutdown}"
        exit 1
        ;;
esac
