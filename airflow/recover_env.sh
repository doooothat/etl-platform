#!/bin/bash

echo "🔄 Starting Environment Recovery..."

# 1. 기존 완료된 Spark Job 정리 (있다면)
echo "🧹 Cleaning up old Spark jobs..."
kubectl delete sparkapplication iceberg-nessie-restore -n spark --ignore-not-found
kubectl delete pod -n spark -l app.kubernetes.io/name=iceberg-nessie-restore --ignore-not-found

# 2. Nessie & MinIO 상태 확인 (생략 가능하지만 안정성을 위해)
echo "⏳ Waiting for Nessie & MinIO to be ready..."
kubectl wait --for=condition=available --timeout=60s deployment/nessie -n nessie
kubectl wait --for=condition=available --timeout=60s deployment/minio -n minio

# 3. 데이터 복구 Job 실행
echo "🚀 Triggering Data Restoration Job..."
kubectl apply -f /Users/smylere/work/etl-platform/spark/examples/spark-iceberg-nessie.yaml

# 4. 완료 대기
echo "👀 Watching recovery progress..."
echo "Command to follow logs: kubectl logs -n spark -f iceberg-nessie-restore-driver"

# 간단한 상태 확인 루프
for i in {1..30}; do
  STATE=$(kubectl get sparkapplication iceberg-nessie-restore -n spark -o jsonpath='{.status.applicationState.state}')
  echo "Current Job State: $STATE"
  if [ "$STATE" == "COMPLETED" ]; then
    echo "✅ Recovery Successful! Data restored in Main and Dev branches."
    exit 0
  fi
  if [ "$STATE" == "FAILED" ]; then
    echo "❌ Recovery Failed. Check logs."
    exit 1
  fi
  sleep 5
done

echo "⚠️ Timed out waiting for job completion. Check manually."
