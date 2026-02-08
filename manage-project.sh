#!/bin/bash

# ==============================================================================
# ETL Platform Management Script
# ==============================================================================
# Description:
#   This script manages Kubernetes workloads and Helm releases for the ETL platform.
#   It supports scaling, re-deploying (Helm), and system shutdown.
#
# Usage:
#   ./manage-project.sh start    - Scale up all project workloads (replicas=1)
#   ./manage-project.sh stop     - Scale down all project workloads (replicas=0)
#   ./manage-project.sh status   - Show current status of all project workloads
#   ./manage-project.sh deploy   - [Re-install] Uninstall and Re-install all Helm charts
#   ./manage-project.sh shutdown - [Advanced] Stop the entire OrbStack engine
#
# Target Namespaces:
#   airflow, analytics, minio, nessie, spark, superset, trino
# ==============================================================================

# Configuration: (Release Name, Namespace, Chart Path, Values Path)
RELEASES=(
    "airflow:airflow:./airflow:./airflow/custom-values.yaml"
    "postgres-analytics:analytics:oci://registry-1.docker.io/bitnamicharts/postgresql:./superset/analytics-values.yaml"
    "minio:minio:./minio/minio:./minio/custom-values.yaml"
    "nessie:nessie:./nessie/nessie:./nessie/custom-values.yaml"
    "spark-operator:spark:spark-operator/spark-operator:./spark/custom-values.yaml"
    "superset:superset:./superset/superset:./superset/custom-values.yaml"
    "trino:trino:trino/trino:./trino/values.yaml"
)

# Namespace list for scaling and status
NAMESPACES=("airflow" "analytics" "minio" "nessie" "spark" "superset" "trino")

function scale_workloads() {
    local replicas=$1
    echo -e "\033[1;33mSetting replicas to $replicas for project namespaces...\033[0m"
    
    for ns in "${NAMESPACES[@]}"; do
        if kubectl get ns "$ns" >/dev/null 2>&1; then
            echo "--- Namespace: $ns ---"
            if [ $(kubectl get deployments -n "$ns" 2>/dev/null | wc -l) -gt 1 ]; then
                kubectl scale deployment --all --replicas=$replicas -n "$ns" --timeout=5s 2>/dev/null
            fi
            if [ $(kubectl get statefulsets -n "$ns" 2>/dev/null | wc -l) -gt 1 ]; then
                kubectl scale statefulset --all --replicas=$replicas -n "$ns" --timeout=5s 2>/dev/null
            fi
            if [ "$replicas" -eq 0 ]; then
                kubectl delete sparkapplications --all -n "$ns" 2>/dev/null
            fi
        fi
    done
}

function deploy_charts() {
    echo -e "\033[1;31mWARNING: This will UNINSTALL and RE-INSTALL all project components.\033[0m"
    echo "This may result in data loss if volumes are not persistent. Continue? (y/n)"
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Deployment cancelled."
        return
    fi

    for entry in "${RELEASES[@]}"; do
        IFS=":" read -r release namespace chart values <<< "$entry"
        echo -e "\n\033[1;34m>>> Processing $release in $namespace <<<\033[0m"
        
        # Uninstall if exists
        echo "Uninstalling $release..."
        helm uninstall "$release" -n "$namespace" 2>/dev/null || echo "$release not found, skipping uninstall."
        
        # Ensure namespace exists
        kubectl create namespace "$namespace" 2>/dev/null || true
        
        # Install
        echo "Installing $release using $chart..."
        if [[ "$chart" == *"spark-operator"* ]]; then
            helm upgrade --install "$release" "$chart" -n "$namespace" -f "$values" --set webhook.enable=true
        elif [[ "$chart" == *"trino"* ]]; then
            helm upgrade --install "$release" "$chart" -n "$namespace" -f "$values"
        else
            helm upgrade --install "$release" "$chart" -n "$namespace" -f "$values"
        fi
    done
    
    echo -e "\n\033[1;32mDeployment complete. Services are starting...\033[0m"
}

case "$1" in
    start)
        scale_workloads 1
        echo -e "\n\033[1;32mProject workloads are scaling up.\033[0m"
        ;;
    stop)
        scale_workloads 0
        echo -e "\n\033[1;33mProject workloads have been scaled to 0.\033[0m"
        ;;
    status)
        for ns in "${NAMESPACES[@]}"; do
            if kubectl get ns "$ns" >/dev/null 2>&1; then
                echo -e "\n\033[1;34mNamespace: $ns\033[0m"
                kubectl get deployments,statefulsets,pods -n "$ns"
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
