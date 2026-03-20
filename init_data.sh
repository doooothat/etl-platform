#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "  $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*"; }
step() { echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "🔷 $*"; }

echo "🔄 Starting Data Initialization for ETL Platform..."
echo "   $(date '+%Y-%m-%d %H:%M:%S')"

# ==============================================================================
# Step 1. MinIO 대기 + iceberg-data 버킷 생성
# ==============================================================================
step "Step 1: MinIO - Waiting & Creating bucket..."

log "Waiting for MinIO to be available..."
kubectl wait --for=condition=available --timeout=120s deployment/minio -n minio
ok "MinIO is ready."

log "Ensuring 'iceberg-data' bucket exists..."
kubectl exec -n minio deploy/minio -- bash -c "
  mc alias set local http://localhost:9000 admin password --quiet
  mc mb local/iceberg-data --ignore-existing
" && ok "Bucket 'iceberg-data' is ready." || warn "Bucket creation failed, Nessie may fail health check."

# ==============================================================================
# Step 2. Nessie 대기 (버킷이 있어야 health check 통과)
# ==============================================================================
step "Step 2: Nessie - Waiting for health check..."

log "Waiting for Nessie to be available (requires iceberg-data bucket)..."
kubectl wait --for=condition=available --timeout=120s deployment/nessie -n nessie
ok "Nessie is ready."

# ==============================================================================
# Step 3. Iceberg + Nessie 샘플 데이터 생성 (Spark Job)
# ==============================================================================
step "Step 3: Spark Job - Creating Iceberg sample data (ecommerce dataset)..."

log "Deleting previous job if exists..."
kubectl delete sparkapplication iceberg-nessie-restore -n spark --ignore-not-found --wait=false

log "Submitting Spark job..."
kubectl apply -f "$SCRIPT_DIR/spark/examples/spark-iceberg-nessie.yaml"

log "Watching Spark Job progress (max 5 min)..."
SPARK_SUCCESS=false
for i in {1..60}; do
  STATE=$(kubectl get sparkapplication iceberg-nessie-restore -n spark \
    -o jsonpath='{.status.applicationState.state}' 2>/dev/null || echo "PENDING")
  printf "\r  [%2d/60] State: %-12s" "$i" "$STATE"
  if [ "$STATE" = "COMPLETED" ]; then
    echo ""
    ok "Iceberg sample data created!"
    log "Tables: iceberg.ecommerce.{customers, products, orders}"
    SPARK_SUCCESS=true
    break
  fi
  if [ "$STATE" = "FAILED" ] || [ "$STATE" = "SUBMISSION_FAILED" ]; then
    echo ""
    fail "Spark Job failed. Debug:"
    log "kubectl logs -n spark -l spark-role=driver --tail=30"
    break
  fi
  sleep 5
done
echo ""

if [ "$SPARK_SUCCESS" = false ]; then
  warn "Spark Job did not complete within timeout. Continuing anyway..."
fi

# ==============================================================================
# Step 4. Superset 대기 + DB 초기화 (ephemeral PostgreSQL이므로 매번 필요)
# ==============================================================================
step "Step 4: Superset - Waiting & Initializing DB..."

log "Waiting for Superset pod to be running..."
SUPERSET_POD=""
for i in {1..30}; do
  SUPERSET_POD=$(kubectl get pods -n superset -l app=superset \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$SUPERSET_POD" ]; then
    log "Superset pod: $SUPERSET_POD"
    break
  fi
  printf "\r  [%2d/30] Waiting for Superset pod..." "$i"
  sleep 10
done
echo ""

if [ -z "$SUPERSET_POD" ]; then
  warn "Superset pod not found. Skipping Superset init."
else
  # PostgreSQL이 ephemeral이므로 매 시작마다 DB 초기화 필요
  log "Running Superset DB initialization (db upgrade + admin user + init)..."
  kubectl exec -n superset "$SUPERSET_POD" -- bash -c "
    set -e
    # DB 마이그레이션
    superset db upgrade 2>&1 | grep -E '(ERROR|WARNING|Upgrading|Running|Done|OK)' || true

    # Admin 계정 생성 (이미 있으면 무시)
    superset fab create-admin \
      --username admin \
      --firstname Superset \
      --lastname Admin \
      --email admin@superset.com \
      --password admin 2>&1 | tail -3

    # 권한/역할 초기화
    superset init 2>&1 | grep -E '(ERROR|Syncing|Creating|Cleaning)' || true

    echo 'SUPERSET_INIT_OK'
  " 2>/dev/null | grep -q "SUPERSET_INIT_OK" \
    && ok "Superset DB initialized." \
    || warn "Superset DB init may have issues (continuing anyway)."

  # ==============================================================================
  # Step 5. Superset Worker + Webserver 파드에 sqlalchemy-trino 설치
  # ==============================================================================
  step "Step 5: Installing sqlalchemy-trino in Superset pods..."

  # Note: bootstrapScript에도 추가해뒀으므로 다음 fresh deploy부터는 자동
  for COMPONENT in "app=superset" "app=superset-worker"; do
    PODS=$(kubectl get pods -n superset -l "$COMPONENT" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for POD in $PODS; do
      log "Installing sqlalchemy-trino in $POD..."
      kubectl exec -n superset "$POD" -- bash -c "
        pip install sqlalchemy-trino \
          --target /app/.venv/lib/python3.10/site-packages \
          --quiet 2>/dev/null
        /app/.venv/bin/python3 -c 'import trino; print(\"trino\", trino.__version__)' 2>/dev/null \
          && echo 'TRINO_OK' || echo 'TRINO_FAIL'
      " 2>/dev/null | grep -q "TRINO_OK" \
        && ok "sqlalchemy-trino ready in $POD" \
        || warn "sqlalchemy-trino install may have failed in $POD"
    done
  done

  # ==============================================================================
  # Step 6. Superset에 Trino DB 연결 자동 등록
  # ==============================================================================
  step "Step 6: Registering Trino DB connection in Superset..."

  TRINO_URI="trino://trino@trino.trino.svc.cluster.local:18080/iceberg"

  # Python 스크립트를 base64로 인코딩 후 전달 (kubectl exec stdin/heredoc 이슈 우회)
  _PY=$(cat <<'PYEOF'
import urllib.request, urllib.error, json, sys
BASE="http://localhost:8088"; TRINO_NAME="Trino (Iceberg/Nessie)"; TRINO_URI="trino://trino@trino.trino.svc.cluster.local:18080/iceberg"
def http(method, path, data=None, headers=None):
    req=urllib.request.Request(BASE+path,data=data,headers=headers or {},method=method)
    try: return json.loads(urllib.request.urlopen(req,timeout=15).read())
    except urllib.error.HTTPError as e: return json.loads(e.read())
    except Exception as e: return {"error":str(e)}
r=http("POST","/api/v1/security/login",data=json.dumps({"username":"admin","password":"admin","provider":"db","refresh":True}).encode(),headers={"Content-Type":"application/json"})
token=r.get("access_token","")
if not token: print("TOKEN_FAIL"); sys.exit(0)
auth={"Authorization":f"Bearer {token}"}
csrf=http("GET","/api/v1/security/csrf_token/",headers=auth).get("result","")
r3=http("GET","/api/v1/database/",headers=auth)
existing=next((str(d["id"]) for d in r3.get("result",[]) if "trino" in d.get("database_name","").lower()),"")
if existing: print(f"ALREADY_EXISTS:{existing}"); sys.exit(0)
h={**auth,"X-CSRFToken":csrf,"Content-Type":"application/json","Referer":BASE}
r4=http("POST","/api/v1/database/",data=json.dumps({"database_name":TRINO_NAME,"sqlalchemy_uri":TRINO_URI,"expose_in_sqllab":True,"allow_run_async":True,"allow_ctas":True,"allow_cvas":True,"allow_dml":True}).encode(),headers=h)
db_id=r4.get("id",""); msg=str(r4.get("message",""))
if db_id: print(f"REGISTERED:{db_id}")
elif "already exists" in msg.lower(): print("ALREADY_EXISTS:name_conflict")
else: print(f"REG_FAIL:{r4}")
PYEOF
  )
  _B64=$(printf '%s' "$_PY" | base64)
  _last_line=$(kubectl exec -n superset "$SUPERSET_POD" -- \
    bash -c "echo '$_B64' | base64 -d | /app/.venv/bin/python3" 2>/dev/null || true)

  case "$_last_line" in
    TOKEN_FAIL*)       warn "Could not get Superset access token. Run init_data.sh again after Superset is fully ready." ;;
    ALREADY_EXISTS:*)  ok  "Trino DB connection already registered (id=${_last_line#ALREADY_EXISTS:})." ;;
    REGISTERED:*)      ok  "Trino DB connection registered in Superset (id=${_last_line#REGISTERED:})." ;;
    REG_FAIL:*)        warn "Trino DB registration failed. Register manually via Superset UI." ;;
    "")                warn "No response from Superset registration script." ;;
  esac
fi

# ==============================================================================
# Done
# ==============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ All initialization tasks completed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 How to use:"
echo "  → Superset:  http://localhost:8088  (admin / admin)"
echo "  → SQL Lab:   Database = 'Trino (Iceberg/Nessie)'  |  Schema = 'ecommerce'"
echo "  → Tables:    customers · products · orders"
echo ""
echo "  Sample query:"
echo "    SELECT p.category,"
echo "           COUNT(o.order_id)            AS order_count,"
echo "           ROUND(SUM(o.total_amount),2) AS total_revenue"
echo "    FROM ecommerce.orders o"
echo "    JOIN ecommerce.products p ON o.product_id = p.product_id"
echo "    WHERE o.status != 'cancelled'"
echo "    GROUP BY p.category"
echo "    ORDER BY total_revenue DESC"
echo ""
