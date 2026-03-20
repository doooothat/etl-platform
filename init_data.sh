#!/bin/bash

echo "🔄 Starting Data Initialization for ETL Platform..."

# 1. Nessie & MinIO 상태 대기
echo "⏳ Waiting for Nessie & MinIO..."
kubectl wait --for=condition=available --timeout=60s deployment/nessie -n nessie
kubectl wait --for=condition=available --timeout=60s deployment/minio -n minio
echo "✅ Storage layer is ready."

# 2. Iceberg + Nessie 샘플 데이터 생성 (Spark Job)
# - nessie.ecommerce.customers / products / orders 테이블을 Iceberg 형식으로 생성
# - Superset은 Trino를 통해 이 데이터를 직접 쿼리함 (별도 SQLite/Postgres 불필요)
echo "🚀 Running Spark Job to create Iceberg sample data (ecommerce dataset)..."

# 기존 Job이 있다면 삭제 (중복 실행 방지)
kubectl delete sparkapplication iceberg-nessie-restore -n spark --ignore-not-found

# 신규 실행
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kubectl apply -f "$SCRIPT_DIR/spark/examples/spark-iceberg-nessie.yaml"

echo "👀 Watching Spark Job progress..."
for i in {1..60}; do
  STATE=$(kubectl get sparkapplication iceberg-nessie-restore -n spark -o jsonpath='{.status.applicationState.state}')
  echo "  [${i}/60] Current Spark State: $STATE"
  if [ "$STATE" == "COMPLETED" ]; then
    echo "✅ Iceberg sample data initialized successfully!"
    echo "   Tables: nessie.ecommerce.customers / products / orders"
    echo "   Query via Trino: SELECT * FROM nessie.ecommerce.orders LIMIT 10"
    break
  fi
  if [ "$STATE" == "FAILED" ]; then
    echo "❌ Spark Job Failed. Check logs:"
    echo "   kubectl logs -n spark -l spark-role=driver"
    break
  fi
  sleep 5
done

# 3. Superset: Trino DB 연결 등록 (API 방식)
echo ""
echo "🔗 Registering Trino connection in Superset..."

# Superset 파드가 Ready 상태일 때까지 대기
SUPERSET_POD=""
for i in {1..24}; do
  SUPERSET_POD=$(kubectl get pods -n superset -l app=superset \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$SUPERSET_POD" ]; then
    echo "  Superset pod found: $SUPERSET_POD"
    break
  fi
  echo "  [${i}/24] Waiting for Superset pod..."
  sleep 10
done

if [ -z "$SUPERSET_POD" ]; then
  echo "⚠️  Superset pod not found. Skipping auto DB registration."
  echo "   수동 등록: Superset UI → Settings → Database Connections → + Database"
  echo "   SQLAlchemy URI: trino://trino@trino.trino.svc.cluster.local:8080/nessie"
else
  # Superset Admin API로 Trino 연결 등록 (이미 존재하면 스킵)
  kubectl exec -n superset "$SUPERSET_POD" -- bash -c "
    ACCESS_TOKEN=\$(curl -s -X POST http://localhost:8088/api/v1/security/login \
      -H 'Content-Type: application/json' \
      -d '{\"username\":\"admin\",\"password\":\"admin\",\"provider\":\"db\",\"refresh\":true}' \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"access_token\"])' 2>/dev/null)

    if [ -z \"\$ACCESS_TOKEN\" ]; then
      echo '  ⚠️  Could not get Superset access token. Register Trino DB manually.'
      exit 0
    fi

    # 기존 Trino DB 연결 존재 여부 확인
    EXISTING=\$(curl -s -X GET http://localhost:8088/api/v1/database/ \
      -H \"Authorization: Bearer \$ACCESS_TOKEN\" \
      | python3 -c 'import sys,json; dbs=json.load(sys.stdin).get(\"result\",[]); print(next((str(d[\"id\"]) for d in dbs if \"trino\" in d.get(\"sqlalchemy_uri\",\"\").lower()), \"\"))' 2>/dev/null)

    if [ -n \"\$EXISTING\" ]; then
      echo \"  ✅ Trino DB already registered (id=\$EXISTING). Skipping.\"
    else
      RESULT=\$(curl -s -X POST http://localhost:8088/api/v1/database/ \
        -H \"Authorization: Bearer \$ACCESS_TOKEN\" \
        -H 'Content-Type: application/json' \
        -d '{
          \"database_name\": \"Trino (Iceberg/Nessie)\",
          \"sqlalchemy_uri\": \"trino://trino@trino.trino.svc.cluster.local:8080/nessie\",
          \"expose_in_sqllab\": true,
          \"allow_run_async\": true,
          \"allow_ctas\": true,
          \"allow_cvas\": true,
          \"allow_dml\": true,
          \"extra\": \"{\\\"engine_params\\\": {\\\"connect_args\\\": {}}}\"
        }')
      DB_ID=\$(echo \"\$RESULT\" | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r.get(\"id\",\"\"))' 2>/dev/null)
      if [ -n \"\$DB_ID\" ]; then
        echo \"  ✅ Trino DB registered in Superset (id=\$DB_ID)\"
      else
        echo \"  ⚠️  Failed to register Trino DB. Response: \$RESULT\"
      fi
    fi
  " || echo "  ⚠️  Could not exec into Superset pod. Register Trino DB manually."
fi

echo ""
echo "✨ All data initialization tasks completed!"
echo ""
echo "📊 Next Steps:"
echo "  1. Open Superset UI: http://localhost:8088  (admin/admin)"
echo "  2. Go to SQL Lab → select 'Trino (Iceberg/Nessie)' database"
echo "  3. Schema: ecommerce | Tables: customers, products, orders"
echo "  4. Sample query:"
echo "     SELECT p.category, SUM(o.total_amount) AS revenue"
echo "     FROM ecommerce.orders o"
echo "     JOIN ecommerce.products p ON o.product_id = p.product_id"
echo "     WHERE o.status = 'completed'"
echo "     GROUP BY p.category ORDER BY revenue DESC"
