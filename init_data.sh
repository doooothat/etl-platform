#!/bin/bash

echo "🔄 Starting Data Initialization for ETL Platform..."

# 1. Nessie & MinIO 상태 대기
echo "⏳ Waiting for Nessie & MinIO..."
kubectl wait --for=condition=available --timeout=60s deployment/nessie -n nessie
kubectl wait --for=condition=available --timeout=60s deployment/minio -n minio
echo "✅ Storage layer is ready."

# 2. 분석 DB (Analytics DB) 샘플 데이터 로딩
echo "📊 Loading Superset Example Data into Analytics DB..."
SUPERSET_POD=$(kubectl get pods -n superset -l app=superset -o jsonpath='{.items[0].metadata.name}')
if [ -z "$SUPERSET_POD" ]; then
    echo "❌ Superset Pod not found. Skipping Analytics DB init."
else
    # 이미 로드 중일 수 있으므로 백그라운드 대신 명시적으로 실행 명령 전달
    kubectl exec -n superset $SUPERSET_POD -- superset load_examples --force
    echo "✅ Analytics DB data loaded."
fi

# 3. Iceberg + Nessie 브랜치/테이블 생성 (Spark Job)
echo "🚀 Running Spark Job for Iceberg & Nessie initialization..."
# 기존 Job이 있다면 삭제 (중복 실행 방지)
kubectl delete sparkapplication iceberg-nessie-restore -n spark --ignore-not-found

# 신규 실행
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kubectl apply -f "$SCRIPT_DIR/spark/examples/spark-iceberg-nessie.yaml"

echo "👀 Watching Spark Job progress..."
for i in {1..30}; do
  STATE=$(kubectl get sparkapplication iceberg-nessie-restore -n spark -o jsonpath='{.status.applicationState.state}')
  echo "Current Spark State: $STATE"
  if [ "$STATE" == "COMPLETED" ]; then
    echo "✅ Nessie/Iceberg data initialized successfully!"
    break
  fi
  if [ "$STATE" == "FAILED" ]; then
    echo "❌ Spark Job Failed. Check logs: kubectl logs -n spark -l app.kubernetes.io/name=iceberg-nessie-restore"
    break
  fi
  sleep 5
done

echo "✨ All data initialization tasks are completed!"
