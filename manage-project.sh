#!/bin/bash
set -euo pipefail

# ==============================================================================
# ETL Platform Management Script
# ==============================================================================
# Load local environment configurations if exists
PROJECT_ROOT=$(pwd)
if [[ -f "local.env" ]]; then
    # shellcheck source=/dev/null
    source "local.env"
fi
PROJECT_ROOT=${PROJECT_ROOT%/} # Trim trailing slash if any

# Validate PROJECT_ROOT
if [[ ! -d "$PROJECT_ROOT" ]]; then
    echo -e "\n\033[1;31m❌ ERROR: PROJECT_ROOT ($PROJECT_ROOT) is not a valid directory!\033[0m"
    echo "Please check your 'local.env' or ensure you are in the correct directory."
    exit 1
fi
# ==============================================================================
# Usage:
#   ./manage-project.sh start [name]    - Ordered startup or start specific component
#   ./manage-project.sh stop [name]     - Scale down all or specific component (wipes PVCs)
#   ./manage-project.sh status [name]   - Show status of all or specific component
#   ./manage-project.sh doctor          - Check local tooling, K8s access, and required files
#   ./manage-project.sh bootstrap       - Prepare Helm repos, namespaces, chart deps, and CRDs
#   ./manage-project.sh deploy [name]   - Uninstall & Re-install all or specific component
#   ./manage-project.sh purge [--yes]   - Delete project Helm releases, K8s resources, namespaces, PVs
#   ./manage-project.sh rebuild-images [--no-cache] - Rebuild local custom Spark/Flink images
#   ./manage-project.sh validate        - Run post-start integration checks
#   ./manage-project.sh provision [--yes] [--no-cache] - Doctor, bootstrap, rebuild, deploy, start, validate
#   ./manage-project.sh integration-test [--yes] [--no-cache] - Purge, rebuild, deploy, start, validate
#   ./manage-project.sh shutdown        - Stop the entire OrbStack engine
#
# Components: keda, airflow, minio, nessie, spark, flink, superset, trino, monitoring
#
# Dependency order for 'start':
#   [Stage 0] KEDA (autoscaler)
#   [Stage 1] MinIO (Object Storage)
#             └─ bucket 'iceberg-data' creation
#   [Stage 1.5] Kafka + Kafka UI
#   [Stage 1.6] Vector log shipper
#   [Stage 2] Nessie (Catalog waits: MinIO + bucket)
#             Spark Operator (waits: MinIO)
#   [Stage 2.5] Hive Metastore (shared view store)
#   [Stage 3] Trino + Spark Thrift Server + sample Iceberg data
#   [Stage 3.6] Flink Kafka -> Iceberg streaming bridge
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
    "spark-operator:spark:./spark:./spark/custom-values.yaml"
    "superset:superset:./superset/superset:./superset/custom-values.yaml"
    "trino:trino:./trino:./trino/values.yaml"
    "hive-metastore:hive-metastore:./hive-metastore:./hive-metastore/values.yaml"
    "prometheus:monitoring:prometheus-community/kube-prometheus-stack:./monitoring/custom-values.yaml"
    # kafka is deployed via kubectl apply (see kafka/kafka.yaml, kafka/kafka-ui.yaml)
)

NAMESPACES=("keda" "airflow" "minio" "nessie" "spark" "flink" "superset" "trino" "monitoring" "kafka" "vector" "hive-metastore")
LOCAL_IMAGES=("custom-spark:4.0.2-nessie" "custom-flink:1.20.3-iceberg")
REQUIRED_TOOLS=("kubectl" "helm" "docker" "curl" "awk" "sed" "grep")
REQUIRED_FILES=(
    "./airflow/Chart.yaml"
    "./airflow/custom-values.yaml"
    "./flink/Dockerfile"
    "./flink/flink.yaml"
    "./flink/sql/k8s_logs_to_iceberg.sql"
    "./hive-metastore/Chart.yaml"
    "./kafka/kafka.yaml"
    "./kafka/kafka-ui.yaml"
    "./minio/minio/Chart.yaml"
    "./monitoring/custom-values.yaml"
    "./nessie/nessie/Chart.yaml"
    "./spark/Chart.yaml"
    "./spark/Dockerfile"
    "./spark/init-data-job.yaml"
    "./spark/spark-thrift-server.yaml"
    "./superset/superset/Chart.yaml"
    "./trino/Chart.yaml"
    "./vector/vector.yaml"
    "./versions.yaml"
)
REQUIRED_CRDS=(
    "scaledobjects.keda.sh"
    "sparkapplications.sparkoperator.k8s.io"
    "scheduledsparkapplications.sparkoperator.k8s.io"
    "prometheuses.monitoring.coreos.com"
    "servicemonitors.monitoring.coreos.com"
    "prometheusrules.monitoring.coreos.com"
    "alertmanagers.monitoring.coreos.com"
)

# ── Helpers ────────────────────────────────────────────────────────────────────

function has_arg() {
    local needle=$1
    shift || true
    for arg in "$@"; do
        if [[ "$arg" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

function confirm_destructive() {
    local message=$1
    shift || true
    if has_arg "--yes" "$@"; then
        return 0
    fi

    echo -e "${C_RED}${message}${C_RESET}"
    echo "Continue? (y/n)"
    read -r confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]]
}

function update_helm_repos() {
    log_wait "Ensuring Helm repositories..."
    helm repo add kedacore https://kedacore.github.io/charts --quiet 2>/dev/null || true
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --quiet 2>/dev/null || true
    helm repo update >/dev/null
    log_ok "Helm repositories are ready."
}

function ensure_namespaces() {
    log_wait "Ensuring project namespaces..."
    for ns in "${NAMESPACES[@]}"; do
        kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    done
    log_ok "Project namespaces are ready."
}

function ensure_chart_dependencies() {
    log_wait "Ensuring local chart dependencies..."
    local charts=("./airflow" "./minio/minio" "./nessie/nessie" "./spark" "./superset/superset" "./hive-metastore" "./trino")
    for chart in "${charts[@]}"; do
        if [[ -f "$chart/Chart.yaml" ]] && grep -q '^dependencies:' "$chart/Chart.yaml"; then
            helm dependency build "$chart" >/dev/null
        fi
    done
    log_ok "Local chart dependencies are ready."
}

function apply_helm_template_crds() {
    local release=$1 chart=$2 namespace=$3
    local rendered
    rendered=$(mktemp)
    helm template "$release" "$chart" -n "$namespace" --include-crds > "$rendered"
    awk '
        function flush() {
            if (doc ~ /(^|\n)kind: CustomResourceDefinition(\n|$)/) {
                printf "%s", doc
            }
        }
        /^---[[:space:]]*$/ {
            flush()
            doc = "---\n"
            next
        }
        { doc = doc $0 "\n" }
        END { flush() }
    ' "$rendered" \
        | kubectl apply --server-side --force-conflicts -f - >/dev/null
    rm -f "$rendered"
}

function ensure_crds() {
    log_wait "Ensuring project CRDs..."
    update_helm_repos

    for crd_file in ./spark/crds/*.yaml; do
        local crd_name
        crd_name=$(sed -n 's/^  name: //p' "$crd_file" | head -n 1)
        if [[ -z "$crd_name" ]]; then
            log_err "Could not determine CRD name from $crd_file"
            return 1
        fi
        if kubectl get crd "$crd_name" >/dev/null 2>&1; then
            log_ok "CRD $crd_name already exists."
        else
            kubectl create -f "$crd_file" >/dev/null
            log_ok "CRD $crd_name created."
        fi
    done

    apply_helm_template_crds keda kedacore/keda keda
    apply_helm_template_crds prometheus prometheus-community/kube-prometheus-stack monitoring

    for crd in "${REQUIRED_CRDS[@]}"; do
        kubectl wait --for=condition=Established --timeout=90s crd/"$crd" >/dev/null
        log_ok "CRD $crd is established."
    done
}

function check_required_crds() {
    log_wait "Checking required CRDs..."
    for crd in "${REQUIRED_CRDS[@]}"; do
        if ! kubectl get crd "$crd" >/dev/null 2>&1; then
            log_err "Missing CRD: $crd"
            return 1
        fi
    done
    log_ok "Required CRDs are present."
}

function doctor_environment() {
    log_stage "Environment Doctor"

    local missing=0
    log_wait "Checking required CLI tools..."
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            log_ok "$tool: $(command -v "$tool")"
        else
            log_err "Missing required tool: $tool"
            missing=1
        fi
    done

    if command -v orbctl >/dev/null 2>&1; then
        log_ok "orbctl: $(command -v orbctl)"
    else
        log_info "orbctl not found; continuing because another local K8s provider may be used."
    fi

    log_wait "Checking Kubernetes connectivity..."
    kubectl version --client >/dev/null
    kubectl cluster-info >/dev/null
    log_ok "Kubernetes cluster is reachable: $(kubectl config current-context)"

    log_wait "Checking Docker daemon..."
    docker info >/dev/null
    log_ok "Docker daemon is reachable."

    log_wait "Checking required repository files..."
    for file in "${REQUIRED_FILES[@]}"; do
        if [[ -e "$file" ]]; then
            log_ok "$file"
        else
            log_err "Missing required file: $file"
            missing=1
        fi
    done

    log_info "Host architecture: $(uname -m)"
    log_info "Project root: $PROJECT_ROOT"

    if [[ "$missing" -ne 0 ]]; then
        return 1
    fi

    log_ok "Environment doctor passed."
}

function bootstrap_environment() {
    log_stage "Bootstrap IaC Prerequisites"
    doctor_environment
    update_helm_repos
    ensure_chart_dependencies
    ensure_namespaces
    ensure_crds
    check_required_crds
    log_ok "Bootstrap completed."
}

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

function ensure_hive_metastore_db() {
    wait_statefulset airflow airflow-postgresql 120
    log_wait "Ensuring Hive Metastore database exists in Airflow PostgreSQL..."
    kubectl exec -n airflow airflow-postgresql-0 -- bash -lc \
        "PGPASSWORD=airflow psql -U airflow -d airflow -tAc \"SELECT 1 FROM pg_database WHERE datname='metastore'\" | grep -q 1 || PGPASSWORD=airflow createdb -U airflow metastore" \
        && log_ok "Hive Metastore database is ready." \
        || log_err "Could not prepare Hive Metastore database."
}

function airflow_table_count() {
    local conn db_user db_pass db_name
    conn=$(kubectl get secret airflow-metadata -n airflow -o jsonpath='{.data.connection}' 2>/dev/null | base64 --decode)
    db_user=$(printf "%s" "$conn" | sed -E 's|^postgresql://([^:]+):.*|\1|')
    db_pass=$(printf "%s" "$conn" | sed -E 's|^postgresql://[^:]+:([^@]+)@.*|\1|')
    db_name=$(printf "%s" "$conn" | sed -E 's|.*:5432/([^?]+).*|\1|')

    kubectl exec -n airflow airflow-postgresql-0 -- bash -lc \
        "PGPASSWORD='$db_pass' psql -U '$db_user' -d '$db_name' -tAc \"SELECT count(*) FROM pg_tables WHERE schemaname='public'\"" \
        2>/dev/null || echo 0
}

function prepare_airflow_database() {
    log_wait "Preparing Airflow database (migrations & admin user)..."

    scale_ns airflow 1 statefulsets
    wait_statefulset airflow airflow-postgresql 120
    wait_statefulset airflow airflow-redis 120

    # If the host or OrbStack stops abruptly while Airflow's ephemeral DB is empty,
    # existing app pods can get stuck forever in wait-for-migrations init containers.
    scale_ns airflow 0 deployments

    kubectl delete job -n airflow airflow-run-airflow-migrations airflow-create-user 2>/dev/null || true

    sed "s|/path/to/project/airflow/dags|$PROJECT_ROOT/airflow/dags|g" ./airflow/custom-values.yaml > ./airflow/custom-values.yaml.tmp
    helm upgrade --install airflow ./airflow -n airflow -f ./airflow/custom-values.yaml.tmp --reuse-values >/dev/null
    rm -f ./airflow/custom-values.yaml.tmp

    log_wait "Verifying Airflow migrations..."
    local table_count=0
    for _retry in {1..12}; do
        table_count=$(airflow_table_count)
        if [[ "$table_count" =~ ^[0-9]+$ && "$table_count" -gt 0 ]]; then
            log_ok "Airflow metadata DB is initialized (${table_count} tables)."
            return 0
        fi
        log_info "  Airflow metadata DB is still empty, retrying in 5s... (${_retry}/12)"
        sleep 5
    done

    log_err "Airflow metadata DB still has no tables after migration attempt."
    log_info "Check: kubectl logs -n airflow job/airflow-run-airflow-migrations"
    return 1
}

function ensure_flink_image() {
    local image="custom-flink:1.20.3-iceberg"
    if docker image inspect "$image" >/dev/null 2>&1; then
        log_ok "Flink image $image is available."
        return 0
    fi

    log_wait "Building local Flink image $image..."
    docker build -t "$image" ./flink >/dev/null
    log_ok "Flink image $image built."
}

function ensure_spark_image() {
    local image="custom-spark:4.0.2-nessie"
    if docker image inspect "$image" >/dev/null 2>&1; then
        log_ok "Spark image $image is available."
        return 0
    fi

    log_wait "Building local Spark image $image..."
    docker build -t "$image" ./spark >/dev/null
    log_ok "Spark image $image built."
}

function rebuild_local_images() {
    local no_cache_flag=""
    if has_arg "--no-cache" "$@"; then
        no_cache_flag="--no-cache"
    fi

    log_stage "Rebuilding Local Custom Images"
    for image in "${LOCAL_IMAGES[@]}"; do
        if docker image inspect "$image" >/dev/null 2>&1; then
            log_wait "Removing local image $image..."
            docker rmi -f "$image" >/dev/null || true
        fi
    done

    log_wait "Building custom-spark:4.0.2-nessie..."
    docker build $no_cache_flag -t custom-spark:4.0.2-nessie ./spark >/dev/null
    log_ok "custom-spark:4.0.2-nessie built."

    log_wait "Building custom-flink:1.20.3-iceberg..."
    docker build $no_cache_flag -t custom-flink:1.20.3-iceberg ./flink >/dev/null
    log_ok "custom-flink:1.20.3-iceberg built."
}

function ensure_keda_scaledobject_crd() {
    if kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1; then
        log_ok "KEDA ScaledObject CRD is available."
        return 0
    fi

    log_wait "Installing missing KEDA CRDs from chart..."
    apply_helm_template_crds keda kedacore/keda keda
    kubectl wait --for=condition=Established --timeout=60s crd/scaledobjects.keda.sh >/dev/null
    log_ok "KEDA ScaledObject CRD is ready."
}

function apply_flink_sql_config() {
    local sql_file="./flink/sql/k8s_logs_to_iceberg.sql"
    if [[ ! -f "$sql_file" ]]; then
        log_err "Missing Flink SQL file: $sql_file"
        return 1
    fi

    kubectl create namespace flink --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl create configmap flink-k8s-logs-sql \
        -n flink \
        --from-file=k8s_logs_to_iceberg.sql="$sql_file" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    log_ok "Flink SQL config is synced from $sql_file."
}

function reset_flink_runtime_state() {
    if ! kubectl get deployment flink-jobmanager -n flink >/dev/null 2>&1; then
        return 0
    fi

    log_wait "Resetting Flink jobs and local checkpoints before resubmission..."
    local running_jobs
    running_jobs=$(
        kubectl exec -n flink deploy/flink-jobmanager -- /opt/flink/bin/flink list -r 2>/dev/null \
            | awk '/ : / && /\((RUNNING|RESTARTING|FAILING|CANCELLING|CREATED|SCHEDULED|DEPLOYING|INITIALIZING)\)$/ {print $4}' \
            || true
    )
    for job_id in $running_jobs; do
        log_info "  Cancelling Flink job $job_id"
        kubectl exec -n flink deploy/flink-jobmanager -- /opt/flink/bin/flink cancel "$job_id" >/dev/null 2>&1 || true
    done

    kubectl exec -n flink deploy/flink-jobmanager -- rm -rf /tmp/flink-checkpoints /tmp/flink-savepoints >/dev/null 2>&1 || true
    kubectl exec -n flink deploy/flink-taskmanager -- rm -rf /tmp/flink-checkpoints /tmp/flink-savepoints >/dev/null 2>&1 || true
    log_ok "Flink runtime state reset."
}

function start_flink_pipeline() {
    log_wait "Starting lightweight Flink Kafka -> Iceberg pipeline..."
    ensure_flink_image
    apply_flink_sql_config

    kubectl delete job flink-k8s-logs-sql-runner -n flink --ignore-not-found >/dev/null
    kubectl apply -f ./flink/flink.yaml >/dev/null
    reset_flink_runtime_state
    kubectl rollout restart deployment/flink-jobmanager deployment/flink-taskmanager -n flink >/dev/null 2>&1 || true
    wait_deploy flink flink-jobmanager 180
    wait_deploy flink flink-taskmanager 180
    reset_flink_runtime_state

    kubectl delete job flink-k8s-logs-sql-runner -n flink --ignore-not-found >/dev/null
    kubectl apply -f ./flink/flink.yaml >/dev/null

    log_wait "Waiting for Flink SQL runner to submit the streaming insert..."
    kubectl wait --for=condition=complete --timeout=120s \
        job/flink-k8s-logs-sql-runner -n flink 2>/dev/null \
        && log_ok "Flink streaming insert submitted." \
        || log_info "Flink SQL runner is still active or needs log inspection."
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
                prepare_airflow_database
                scale_ns airflow 1 deployments
                wait_deploy airflow airflow-api-server 180
                wait_deploy airflow airflow-scheduler 180
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
                ensure_spark_image
                scale_ns spark 1
                wait_deploy spark spark-operator-controller 120
                wait_deploy spark spark-operator-webhook 120

                kubectl scale deployment spark-thrift-server --replicas=1 -n spark 2>/dev/null || true
                kubectl rollout status deployment/spark-thrift-server -n spark --timeout=120s 2>/dev/null \
                    && log_ok "Spark Thrift Server is ready." \
                    || log_info "Spark Thrift Server still starting (non-critical)."

                log_wait "Refreshing Iceberg sample data via Spark Job..."
                kubectl delete sparkapplication iceberg-nessie-restore -n spark --ignore-not-found --wait=false >/dev/null
                kubectl apply -f ./spark/init-data-job.yaml >/dev/null
                log_info "Sample data generation started in background (sparkapplication/iceberg-nessie-restore)."
                ;;
            flink)
                log_stage "Starting Flink Pipeline"
                start_flink_pipeline
                ;;
            hive-metastore)
                log_stage "Starting Hive Metastore"
                scale_ns airflow 1 statefulsets
                ensure_hive_metastore_db
                scale_ns hive-metastore 1
                wait_deploy hive-metastore hive-metastore 120
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
    ensure_keda_scaledobject_crd

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
    # Stage 1.5: Kafka (Streaming Message Bus) – Apache official image
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 1.5: Kafka (Message Bus)"
    kubectl create namespace kafka 2>/dev/null || true
    kubectl apply -f ./kafka/kafka.yaml --namespace kafka >/dev/null
    kubectl apply -f ./kafka/kafka-ui.yaml --namespace kafka >/dev/null
    # Wait for Kafka Broker StatefulSet and UI Deployment
    wait_statefulset kafka kafka 180
    wait_deploy kafka kafka-ui 60

    # ────────────────────────────────────────────────────────────────
    # Stage 1.6: Vector (Log Shipper)
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 1.6: Vector (Log Shipping)"
    kubectl create namespace vector 2>/dev/null || true
    kubectl apply -f ./vector/vector.yaml --namespace vector >/dev/null
    # Vector is a DaemonSet, so we wait for its pods to be ready
    log_wait "Waiting for Vector DaemonSet..."
    sleep 5


    # ────────────────────────────────────────────────────────────────
    # Stage 2: Nessie + Spark Operator (parallel, both need MinIO)
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 2: Nessie + Spark Operator (parallel)"
    ensure_spark_image

    scale_ns nessie 1
    scale_ns spark 1
    # Spark Thrift Server should be started in Stage 3, so scale down now 
    # (Prevents Thrift Server from connecting before Nessie is fully ready)
    kubectl scale deployment spark-thrift-server --replicas=0 -n spark 2>/dev/null || true

    wait_deploy nessie nessie 180      # Nessie health-checks MinIO bucket
    wait_deploy spark spark-operator-controller 120
    wait_deploy spark spark-operator-webhook 120

    log_stage "Stage 2.5: Hive Metastore (Shared View Store)"
    scale_ns airflow 1 statefulsets
    ensure_hive_metastore_db
    scale_ns hive-metastore 1
    wait_deploy hive-metastore hive-metastore 120

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
    kubectl apply -f ./spark/init-data-job.yaml >/dev/null
    
    # Wait for data load (async process, but do a minimum check)
    log_info "Sample data generation started in background (sparkapplication/iceberg-nessie-restore)."

    # ────────────────────────────────────────────────────────────────
    # Stage 3.6: Flink local streaming bridge (Kafka -> Iceberg bronze)
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 3.6: Flink (Kafka → Iceberg Bronze)"
    start_flink_pipeline

    # ────────────────────────────────────────────────────────────────
    # Stage 4a: Airflow
    #   airflow-postgresql → airflow-redis → Migrations → Airflow apps
    # ────────────────────────────────────────────────────────────────
    log_stage "Stage 4a: Airflow (PostgreSQL → Redis → Migrations → Apps)"

    prepare_airflow_database

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
    echo -e "  Flink    → http://localhost:8081"
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
            kubectl delete daemonset --all -n "$ns" 2>/dev/null || true
            
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
            kubectl delete job --all -n "$ns" 2>/dev/null || true
            
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

# ── Purge (Full runtime reset) ────────────────────────────────────────────────
function purge_runtime() {
    if ! confirm_destructive "WARNING: This will delete project Helm releases, kubectl-managed resources, namespaces, PVCs, and PVs. Git files and local source changes are not touched." "$@"; then
        echo "Purge cancelled."
        return 0
    fi

    log_stage "Purging Project Runtime"

    log_wait "Uninstalling Helm releases..."
    for entry in "${RELEASES[@]}"; do
        IFS=":" read -r release namespace chart values <<< "$entry"
        helm uninstall "$release" -n "$namespace" >/dev/null 2>&1 || true
    done

    log_wait "Deleting kubectl-managed project resources..."
    kubectl delete -f ./spark/spark-thrift-server.yaml --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete -f ./flink/flink.yaml --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete -f ./kafka/kafka-ui.yaml -n kafka --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete -f ./kafka/kafka.yaml -n kafka --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete -f ./vector/vector.yaml -n vector --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete sparkapplications --all -n spark >/dev/null 2>&1 || true

    log_wait "Deleting project namespaces..."
    for ns in "${NAMESPACES[@]}"; do
        kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done

    log_wait "Waiting for namespaces to terminate..."
    for ns in "${NAMESPACES[@]}"; do
        for _retry in {1..60}; do
            if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
                break
            fi
            sleep 2
        done
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            log_err "Namespace $ns is still terminating after waiting."
            return 1
        fi
    done

    log_wait "Removing project persistent volumes..."
    kubectl delete pv --all >/dev/null 2>&1 || true

    log_ok "Project runtime purge complete."
}

# ── Deploy (Helm install/upgrade) ──────────────────────────────────────────────
function deploy_charts() {
    local target_release="$1"  # Optional: specific release name (e.g., "keda", "airflow")
    shift || true

    if [[ -z "$target_release" ]]; then
        if ! confirm_destructive "WARNING: This will UNINSTALL and RE-INSTALL all project components. This may result in data loss if volumes are not persistent." "$@"; then
            echo "Deployment cancelled."
            return 0
        fi
    else
        echo -e "${C_YELLOW}Deploying only: $target_release${C_RESET}"
    fi

    update_helm_repos

    # kafka is deployed via kubectl apply, not Helm
    if [[ "$target_release" == "kafka" || "$target_release" == "kafka-ui" ]]; then
        kubectl create namespace kafka 2>/dev/null || true
        echo -e "\n${C_BLUE}>>> Deploying Kafka via kubectl apply <<<${C_RESET}"
        kubectl apply -f ./kafka/kafka.yaml -n kafka
        kubectl apply -f ./kafka/kafka-ui.yaml -n kafka
        echo -e "Deployment complete. Run './manage-project.sh start' to bring services up."
        return
    fi
    if [[ "$target_release" == "vector" ]]; then
        kubectl create namespace vector 2>/dev/null || true
        echo -e "\n${C_BLUE}>>> Deploying Vector via kubectl apply <<<${C_RESET}"
        kubectl apply -f ./vector/vector.yaml -n vector
        echo -e "Deployment complete. Run './manage-project.sh start' to bring services up."
        return
    fi
    if [[ "$target_release" == "flink" ]]; then
        kubectl create namespace flink 2>/dev/null || true
        echo -e "\n${C_BLUE}>>> Deploying Flink via kubectl apply <<<${C_RESET}"
        ensure_flink_image
        apply_flink_sql_config
        kubectl apply -f ./flink/flink.yaml -n flink
        echo -e "Deployment complete. Run './manage-project.sh start flink' to bring Flink up."
        return
    fi
    if [[ "$target_release" == "spark-operator" ]]; then
        ensure_spark_image
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
        
        # Create a temporary local values file for dynamic path injection
        case "$release" in
            keda)
                helm upgrade --install "$release" "$chart" -n "$namespace"
                ensure_keda_scaledobject_crd
                ;;
            airflow)
                log_wait "Injecting local paths into $release..."
                sed "s|/path/to/project/airflow/dags|$PROJECT_ROOT/airflow/dags|g" "$values" > "${values}.tmp"
                helm upgrade --install "$release" "$chart" -n "$namespace" -f "${values}.tmp"
                rm -f "${values}.tmp"
                ;;
            spark-operator)
                helm upgrade --install "$release" "$chart" \
                    -n "$namespace" -f "$values" --set webhook.enable=true
                ;;
            *)
                helm upgrade --install "$release" "$chart" -n "$namespace" -f "$values"
                ;;
        esac
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

# ── Validation ────────────────────────────────────────────────────────────────
function validate_integration() {
    log_stage "Integration Validation"

    check_required_crds

    log_wait "Checking project pods..."
    local bad_pods
    bad_pods=$(kubectl get pods -A 2>/dev/null | awk '
        NR > 1 && $1 ~ /^(keda|airflow|minio|nessie|spark|flink|superset|trino|monitoring|kafka|vector|hive-metastore)$/ && $4 != "Running" && $4 != "Completed" {print}
    ')
    if [[ -n "$bad_pods" ]]; then
        log_err "Some project pods are not Running/Completed:"
        echo "$bad_pods"
        return 1
    fi
    log_ok "All project pods are Running or Completed."

    log_wait "Checking Spark sample restore state..."
    local spark_state
    spark_state=$(kubectl get sparkapplication iceberg-nessie-restore -n spark -o jsonpath='{.status.applicationState.state}' 2>/dev/null || true)
    if [[ "$spark_state" != "COMPLETED" ]]; then
        log_err "Spark restore state is '$spark_state' (expected COMPLETED)."
        return 1
    fi
    log_ok "Spark restore completed."

    log_wait "Checking Nessie local MinIO catalog settings..."
    local nessie_config
    nessie_config=$(kubectl get cm -n nessie nessie -o jsonpath='{.data.application\.properties}' 2>/dev/null || true)
    if ! grep -q 'nessie.catalog.warehouses."local".location=s3://iceberg-data/' <<< "$nessie_config"; then
        log_err "Nessie warehouse is not configured as s3://iceberg-data/."
        return 1
    fi
    if ! grep -q 'nessie.catalog.service.s3.default-options.request-signing-enabled=false' <<< "$nessie_config"; then
        log_err "Nessie S3 request signing is not disabled for local MinIO."
        return 1
    fi
    log_ok "Nessie catalog settings are aligned."

    log_wait "Checking Trino Iceberg queries..."
    local counts log_count
    counts=$(kubectl exec -n trino deploy/trino -- trino --execute \
        "SELECT count(*) FROM iceberg.ecommerce.customers; SELECT count(*) FROM iceberg.logs.k8s_logs_bronze" 2>/dev/null || true)
    if ! grep -q '"15"' <<< "$counts"; then
        log_err "Trino customer count validation failed."
        echo "$counts"
        return 1
    fi
    log_count=$(tail -n 1 <<< "$counts" | tr -d '"')
    if ! [[ "$log_count" =~ ^[0-9]+$ ]]; then
        log_err "Trino log table count validation failed."
        echo "$counts"
        return 1
    fi
    log_ok "Trino Iceberg queries succeeded."

    log_wait "Checking Flink streaming job..."
    local flink_overview
    flink_overview=$(curl -sS http://localhost:8081/jobs/overview 2>/dev/null || true)
    if ! grep -q '"state":"RUNNING"' <<< "$flink_overview" || ! grep -q '"running":2' <<< "$flink_overview" || ! grep -q '"failed":0' <<< "$flink_overview"; then
        log_err "Flink job is not healthy."
        echo "$flink_overview"
        return 1
    fi
    log_ok "Flink job is RUNNING with 2/2 tasks and 0 failed tasks."

    log_ok "Integration validation passed."
}

function run_integration_test() {
    if ! confirm_destructive "WARNING: Integration test will purge the local project runtime, rebuild custom images, redeploy everything, and start the full platform." "$@"; then
        echo "Integration test cancelled."
        return 0
    fi

    purge_runtime --yes
    rebuild_local_images "$@"
    deploy_charts "" --yes
    start_ordered
    validate_integration
}

function provision_environment() {
    if ! confirm_destructive "WARNING: Provision will bootstrap prerequisites, rebuild custom images, deploy all components, start the full platform, and validate it." "$@"; then
        echo "Provision cancelled."
        return 0
    fi

    bootstrap_environment
    rebuild_local_images "$@"
    deploy_charts "" --yes
    start_ordered
    validate_integration
}

# ── Main ───────────────────────────────────────────────────────────────────────
case "${1:-}" in
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
    doctor)
        doctor_environment
        ;;
    bootstrap)
        bootstrap_environment
        ;;
    deploy)
        if [[ "${2:-}" == "--yes" ]]; then
            deploy_charts "" "${@:2}"
        else
            deploy_charts "${2:-}" "${@:3}"  # Pass optional second argument (specific release name)
        fi
        ;;
    purge)
        purge_runtime "${@:2}"
        ;;
    rebuild-images)
        rebuild_local_images "${@:2}"
        ;;
    validate)
        validate_integration
        ;;
    provision)
        provision_environment "${@:2}"
        ;;
    integration-test)
        run_integration_test "${@:2}"
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
        echo "Usage: $0 {start|stop|status|doctor|bootstrap|deploy [name]|purge|rebuild-images|validate|provision|integration-test|shutdown}"
        echo ""
        echo "Examples:"
        echo "  $0 start            # Start all"
        echo "  $0 stop             # Stop all"
        echo "  $0 start superset   # Start only Superset"
        echo "  $0 stop airflow     # Stop only Airflow"
        echo "  $0 status trino     # Status of Trino"
        echo "  $0 doctor           # Check local tools, cluster access, and required files"
        echo "  $0 bootstrap        # Prepare Helm repos, namespaces, chart deps, and CRDs"
        echo "  $0 purge --yes      # Delete project runtime resources"
        echo "  $0 rebuild-images --no-cache"
        echo "  $0 provision --yes --no-cache"
        echo "  $0 integration-test --yes --no-cache"
        exit 1
        ;;
esac
