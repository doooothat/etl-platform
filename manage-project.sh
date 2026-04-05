#!/bin/bash
set -euo pipefail

# ==============================================================================
# ETL Platform Management Script
# ==============================================================================
# Usage:
#   ./manage-project.sh start [name]    - Ordered startup or start specific component
#   ./manage-project.sh stop [name]     - Scale down all or specific component (wipes PVCs)
#   ./manage-project.sh status [name]   - Show status of all or specific component
#   ./manage-project.sh deploy [name]   - Uninstall & Re-install all or specific component
#   ./manage-project.sh shutdown        - Stop the entire OrbStack engine
#
# Components: keda, airflow, minio, nessie, spark, superset, trino, monitoring
#
# Dependency order for 'start':
#   [Stage 0] KEDA (autoscaler)
#   [Stage 1] MinIO (Object Storage)
#             └─ bucket 'iceberg-data' creation
#   [Stage 2] Nessie (Catalog waits: MinIO + bucket)
#             Spark Operator (waits: MinIO)
#   [Stage 3] Trino (Query Engine waits: Nessie ready)
#             Spark Thrift Server (waits: Spark Operator)
#   [Stage 4] Airflow & Superset (Apps wait: DB/Redis Ready)
#   [Stage 5] Data Integration (runs init_data.sh for sample data & DB links)
#   [Stage 6] Monitoring (Prometheus & Grafana)
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
    "trino:trino:./trino:./trino/values.yaml"
    "prometheus:monitoring:prometheus-community/kube-prometheus-stack:./monitoring/custom-values.yaml"
)

NAMESPACES=("keda" "airflow" "minio" "nessie" "spark" "superset" "trino" "monitoring")

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
            kubectl scale deployment --all --replicas="$replicas" -n "$ns" 2>/dev/null || true
        fi
    fi
    if [[ "$mode" == "both" || "$mode" == "statefulsets" ]]; then
        if [ "$(kubectl get statefulsets -n "$ns" 2>/dev/null | wc -l)" -gt 1 ]; then
            kubectl scale statefulset --all --replicas="$replicas" -n "$ns" 2>/dev/null || true
        fi
    fi
}

# get_ns_by_name <name>
# Resolves a component name (release or namespace) to its namespace
function get_ns_by_name() {
    local target=$1
    # Check direct namespace match
    for ns in "${NAMESPACES[@]}"; do
        if [[ "$ns" == "$target" ]]; then echo "$ns"; return 0; fi
    done
    # Check release name match
    for entry in "${RELEASES[@]}"; do
        IFS=":" read -r release namespace chart values <<< "$entry"
        if [[ "$release" == "$target" ]]; then echo "$namespace"; return 0; fi
    done
    return 1
}

# ── Ordered Start ──────────────────────────────────────────────────────────────
function start_ordered() {
    local target_comp=${1:-""}
    
    if [[ -n "$target_comp" ]]; then
        local ns
        ns=$(get_ns_by_name "$target_comp") || { log_err "Unknown component: $target_comp"; return 1; }
        echo -e "${C_BOLD}🚀 Starting specific component: $target_comp ($ns)...${C_RESET}"
        
        case "$ns" in
            airflow)
                log_stage "Starting Airflow Stack"
                scale_ns airflow 1 statefulsets
                wait_statefulset airflow airflow-postgresql 60
                scale_ns airflow 1 deployments
                ;;
            superset)
                log_stage "Starting Superset Stack"
                scale_ns superset 1 statefulsets
                wait_statefulset superset superset-postgresql 60
                scale_ns superset 1 deployments
                ;;
            monitoring)
                log_stage "Starting Monitoring Stack"
                kubectl patch prometheus prometheus-kube-prometheus-prometheus -n monitoring --type='merge' -p '{"spec": {"replicas": 1}}' 2>/dev/null || true
                scale_ns monitoring 1
                ;;
            spark)
                log_stage "Starting Spark Infrastructure"
                scale_ns spark 1
                ;;
            *)
                log_stage "Starting $ns"
                scale_ns "$ns" 1
                ;;
        esac
        log_ok "$target_comp started."
        return 0
    fi

    echo -e "${C_BOLD}🚀 Starting Full ETL Platform (dependency-ordered)...${C_RESET}"
    echo -e "   $(date '+%Y-%m-%d %H:%M:%S')"

    # ────────────────────────────────────────────────────────────────
    # Stage 0: KEDA (autoscaler, no dependencies)
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 0: KEDA"
    scale_ns keda 1
    # KEDA is usually already running — quick check only
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
    # Spark Thrift Server should be started in Stage 3, so scale down now 
    # (Prevents Thrift Server from connecting before Nessie is fully ready)
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
    # Wait for Trino ready (check Nessie integration)
    wait_deploy trino trino 180

    # Start Thrift Server after Trino and Nessie are fully ready
    log_wait "Starting Spark Thrift Server..."
    kubectl scale deployment spark-thrift-server --replicas=1 -n spark 2>/dev/null || true

    # Thrift Server waits with best-effort
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
    
    # Wait for data load (async process, but do a minimum check)
    log_info "Sample data generation started in background (sparkapplication/iceberg-nessie-restore)."

    # ────────────────────────────────────────────────────────────────
    # Stage 4a: Airflow
    #   airflow-postgresql → airflow-redis → Migrations → Airflow apps
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 4a: Airflow (PostgreSQL → Redis → Migrations → Apps)"

    # Start DB and Redis first
    scale_ns airflow 1 statefulsets
    wait_statefulset airflow airflow-postgresql 120
    wait_statefulset airflow airflow-redis 120

    # If DB is ephemeral, migration may be needed upon restart
    log_wait "Preparing Airflow database (migrations & admin user)..."
    # Delete existing Jobs to allow recreation
    kubectl delete job -n airflow airflow-run-airflow-migrations airflow-create-user 2>/dev/null || true
    
    # Run migrations via Helm upgrade (handles Wait-for-migrations Init container)
    helm upgrade --install airflow ./airflow -n airflow -f ./airflow/custom-values.yaml --reuse-values >/dev/null

    log_wait "Waiting for Airflow migrations to complete..."
    kubectl wait --for=condition=complete --timeout=180s \
        job/airflow-run-airflow-migrations -n airflow 2>/dev/null \
        && log_ok "Airflow migrations completed." \
        || log_info "Migration job timed out — checking logs might be necessary."

    # Start Deployments next
    scale_ns airflow 1 deployments
    # Check api-server

    # ────────────────────────────────────────────────────────────────
    # Stage 4b: Superset
    #   superset-postgresql → superset-redis → DB Init → Superset apps
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 4b: Superset (PostgreSQL → Redis → App)"

    scale_ns superset 1 statefulsets
    wait_statefulset superset superset-postgresql 120
    wait_statefulset superset superset-redis-master 120

    # Initialize Superset for ephemeral DB (migrations + admin)
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
    # Stage 6: Monitoring (Prometheus & Grafana)
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 6: Monitoring (Prometheus & Grafana)"
    
    # Restore Prometheus replicas to 1 (trigger Operator to start)
    kubectl patch prometheus prometheus-kube-prometheus-prometheus -n monitoring --type='merge' -p '{"spec": {"replicas": 1}}' 2>/dev/null || true
    
    scale_ns monitoring 1 deployments
    kubectl wait --for=condition=available --timeout=120s \
        deployment/prometheus-grafana -n monitoring 2>/dev/null \
        && log_ok "Grafana is ready." \
        || log_info "Grafana still starting..."

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
    echo -e "  Grafana  → http://localhost:3000  (admin / admin)"
}

# ── Stop (Scale down & Cleanup) ────────────────────────────────────────────────
function stop_workloads() {
    local target_comp=${1:-""}
    local targets=()

    if [[ -n "$target_comp" ]]; then
        local ns
        ns=$(get_ns_by_name "$target_comp") || { log_err "Unknown component: $target_comp"; return 1; }
        targets=("$ns")
        echo -e "${C_YELLOW}Stopping component: $target_comp ($ns)...${C_RESET}"
    else
        targets=("${NAMESPACES[@]}")
        echo -e "${C_YELLOW}Scaling down all project workloads and completely removing persistent storage...${C_RESET}"
    fi

    for ns in "${targets[@]}"; do
        if kubectl get ns "$ns" >/dev/null 2>&1; then
            echo "  --- $ns ---"
            
            # Prevent Monitoring Prometheus from reconciling back to life
            if [[ "$ns" == "monitoring" ]]; then
                kubectl patch prometheus prometheus-kube-prometheus-prometheus -n monitoring --type='merge' -p '{"spec": {"replicas": 0}}' 2>/dev/null || true
            fi

            scale_ns "$ns" 0
            
            # Clean up Airflow Redis Pod zombie processes
            if [[ "$ns" == "airflow" ]]; then
                if kubectl get pod airflow-redis-0 -n airflow >/dev/null 2>&1; then
                    kubectl patch pod airflow-redis-0 -n airflow -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
                    kubectl delete pod airflow-redis-0 -n airflow --force --grace-period=0 2>/dev/null || true
                fi
                if command -v docker >/dev/null 2>&1; then
                    docker ps -q --filter "name=airflow-redis" | xargs -r docker rm -f 2>/dev/null || true
                fi
            fi

            # Double-check Monitoring shutdown
            if [[ "$ns" == "monitoring" ]]; then
                kubectl scale statefulset prometheus-prometheus-kube-prometheus-prometheus -n monitoring --replicas=0 2>/dev/null || true
            fi
            
            kubectl delete sparkapplications --all -n "$ns" 2>/dev/null || true
            
            # Force delete PVCs and remove Finalizers
            kubectl patch pvc --all -n "$ns" -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
            kubectl delete pvc --all -n "$ns" --force --grace-period=0 2>/dev/null || true
        fi
    done
    
    if [[ -z "$target_comp" ]]; then
        # Completely remove all Persistent Volumes only during full stop
        kubectl delete pv --all 2>/dev/null || true
        echo -e "${C_YELLOW}All workloads scaled to 0, and PVCs/PVs wiped clean.${C_RESET}"
    else
        echo -e "${C_YELLOW}Component $target_comp scaled to 0 and PVCs cleaned.${C_RESET}"
    fi
}

# ── Deploy (Helm install/upgrade) ──────────────────────────────────────────────
function deploy_charts() {
    local target_release="$1"  # Optional: specific release name (e.g., "keda", "airflow")

    if [[ -z "$target_release" ]]; then
        echo -e "${C_RED}WARNING: This will UNINSTALL and RE-INSTALL all project components.${C_RESET}"
        echo "This may result in data loss if volumes are not persistent. Continue? (y/n)"
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Deployment cancelled."
            return
        fi
    else
        echo -e "${C_YELLOW}Deploying only: $target_release${C_RESET}"
    fi

    for entry in "${RELEASES[@]}"; do
        IFS=":" read -r release namespace chart values <<< "$entry"

        # Skip if target is specified and doesn't match
        if [[ -n "$target_release" && "$release" != "$target_release" ]]; then
            continue
        fi

        echo -e "\n${C_BLUE}>>> Processing $release in $namespace <<<${C_RESET}"

        echo "  Uninstalling $release..."
        helm uninstall "$release" -n "$namespace" 2>/dev/null \
            || echo "  $release not found, skipping uninstall."

        kubectl create namespace "$namespace" 2>/dev/null || true

        echo "  Installing $release using $chart..."
        if [[ "$chart" == *"spark-operator"* ]]; then
            # Pinned to version 2.3.0 due to compatibility issues with 2.4.0
            helm upgrade --install "$release" "$chart" \
                -n "$namespace" -f "$values" --set webhook.enable=true --version 2.3.0
        else
            helm upgrade --install "$release" "$chart" \
                -n "$namespace" -f "$values"
        fi
    done

    # Deploy Spark Thrift Server if spark-operator was deployed
    if [[ -z "$target_release" || "$target_release" == "spark-operator" ]]; then
        echo -e "\n${C_BLUE}>>> Deploying Spark Thrift Server <<<${C_RESET}"
        kubectl delete -f ./spark/spark-thrift-server.yaml 2>/dev/null \
            || echo "  Spark Thrift Server not found, skipping delete."
        kubectl apply -f ./spark/spark-thrift-server.yaml
    fi

    echo -e "\n${C_GREEN}Deployment complete. Run './manage-project.sh start' to bring services up.${C_RESET}"
}

# ── Main ───────────────────────────────────────────────────────────────────────
case "$1" in
    start)
        start_ordered "${2:-}"
        ;;
    stop)
        stop_workloads "${2:-}"
        ;;
    status)
        if [[ -n "${2:-}" ]]; then
            ns=$(get_ns_by_name "$2") || { log_err "Unknown component: $2"; exit 1; }
            echo -e "\n${C_BLUE}Namespace: $ns${C_RESET}"
            kubectl get deployments,statefulsets,pods -n "$ns" 2>/dev/null
        else
            for ns in "${NAMESPACES[@]}"; do
                if kubectl get ns "$ns" >/dev/null 2>&1; then
                    echo -e "\n${C_BLUE}Namespace: $ns${C_RESET}"
                    kubectl get deployments,statefulsets,pods -n "$ns" 2>/dev/null
                fi
            done
        fi
        ;;
    deploy)
        deploy_charts "${2:-}"  # Pass optional second argument (specific release name)
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
        echo "Usage: $0 {start|stop|status|deploy [name]|shutdown}"
        echo ""
        echo "Examples:"
        echo "  $0 start            # Start all"
        echo "  $0 stop             # Stop all"
        echo "  $0 start superset   # Start only Superset"
        echo "  $0 stop airflow     # Stop only Airflow"
        echo "  $0 status trino     # Status of Trino"
        exit 1
        ;;
esac
