# 🤝 AI Agent Handoff (Finalized Session)

이 문서는 세션 종료 시점의 프로젝트 상태와 다음 작업자를 위한 가이드를 담고 있습니다.

## 🕒 마지막 업데이트
- **일시**: 2026-03-21T23:45:00+09:00
- **에이전트**: Claude Code
- **상태**: 전체 플랫폼 재배포 완료 및 선택적 배포 기능 추가

## 🛠️ 금일 작업 완료 사항

### 1. 전체 플랫폼 재배포 (Clean Slate)
- **작업**: 모든 Helm release 삭제 후 재설치
- **해결한 문제**:
  - Nessie `CreateContainerConfigError` → MinIO credential secret 생성 (`rootUser`/`rootPassword`)
  - Spark Operator Controller `CrashLoopBackOff` → Helm chart 버전 다운그레이드 (2.4.0 → 2.3.0)
  - Superset init-db 실패 흔적 정리

### 2. 선택적 컴포넌트 배포 기능 추가
- **파일**: `manage-project.sh`
- **기능**: 개별 컴포넌트만 재배포 가능
  ```bash
  ./manage-project.sh deploy              # 전체 재설치
  ./manage-project.sh deploy keda         # KEDA만 재설치
  ./manage-project.sh deploy nessie       # Nessie만 재설치
  ./manage-project.sh deploy spark-operator  # Spark Operator만 재설치
  ```
- **커밋**: `99dc9ca` - feat: Add selective component deployment to manage-project.sh
- **이점**: 문제 발생 시 전체 플랫폼 재구축 없이 특정 컴포넌트만 빠르게 재배포

### 3. 샘플 데이터 초기화 완료
- **스크립트**: `./init_data.sh` 실행 완료
- **적재된 데이터**:
  - `iceberg.ecommerce.customers` (15 rows)
  - `iceberg.ecommerce.products` (14 rows)
  - `iceberg.ecommerce.orders` (20 rows)
- **Superset 연동**: Trino DB 연결 자동 등록 완료

## 📊 현재 시스템 상태

### 실행 중인 서비스 (23 pods)
| Service | Status | Pods | URL |
|---------|--------|------|-----|
| KEDA | ✅ Running | 3/3 | - |
| Airflow | ✅ Running | 8/8 | http://localhost:8080 (admin/admin) |
| MinIO | ✅ Running | 1/1 | http://localhost:9001 (admin/password) |
| Nessie | ✅ Running | 1/1 | ClusterIP:19120 |
| Spark | ✅ Running | 3/3 | Thrift:10000, UI:4040 |
| Superset | ✅ Running | 4/4 + 1 Completed | http://localhost:8088 (admin/admin) |
| Trino | ✅ Running | 3/3 | http://localhost:18080 |

### 주요 인프라 특성
- **데이터 휘발성**: 모든 DB/Storage는 `persistence.enabled: false` (ephemeral)
- **Nessie Catalog**: `IN_MEMORY` (pod 재시작 시 초기화 필요)
- **Airflow DAGs**: `hostPath` mount → teardown 시에도 보존
- **MinIO**: Standalone mode, `iceberg-data` bucket 자동 생성
- **Spark Operator**: Chart v2.3.0 사용 (v2.4.0 플래그 호환성 이슈로 다운그레이드)

## 🔧 주요 운영 명령어

```bash
# 상태 확인
./manage-project.sh status

# 전체 중지/시작
./manage-project.sh stop
./manage-project.sh start

# 개별 컴포넌트 재배포
./manage-project.sh deploy nessie
./manage-project.sh deploy spark-operator

# 전체 재설치
./manage-project.sh deploy          # 확인 프롬프트 표시
./init_data.sh                     # 데이터 초기화

# OrbStack 전체 종료
./manage-project.sh shutdown
```

## ⚠️ 알려진 이슈 및 해결 방법

### 1. Nessie CreateContainerConfigError
**원인**: `minio-creds` secret 없음
**해결**:
```bash
kubectl create secret generic minio-creds \
  --from-literal=rootUser=admin \
  --from-literal=rootPassword=password \
  -n nessie
kubectl rollout restart deployment nessie -n nessie
```

### 2. Spark Operator CrashLoopBackOff
**원인**: Helm chart 2.4.0의 `--scheduled-spark-application-timestamp-precision` 플래그 미지원
**해결**: Chart v2.3.0으로 다운그레이드 (이미 적용됨)

### 3. Airflow Namespace Terminating 멈춤
**원인**: StatefulSet pod (redis) finalizer 걸림
**해결**:
```bash
kubectl delete pod airflow-redis-0 -n airflow --force --grace-period=0
kubectl get namespace airflow -o json | jq '.spec.finalizers = []' | \
  kubectl replace --raw /api/v1/namespaces/airflow/finalize -f -
```

## 📝 다음 세션 작업 제안

1. **Airflow DAG 개발**: 커머스 트래픽 시뮬레이션 DAG 구현
   - PVC 없이 Iceberg에 데이터 적재
   - Spark 실행 방법 선택 (Thrift Server JDBC vs KubernetesPodOperator)

2. **MLflow 통합 검토**: 현재 프로젝트에 통합 vs 별도 구성 결정
   - 리소스 여유 확인 (현재 60% 사용 중)
   - MinIO를 artifact store로 활용 가능

3. **모니터링 스택 추가**: Grafana + Prometheus (lightweight config)
   - 예상 추가 리소스: ~700MB
   - 최종 메모리 사용: ~11GB/14GB (80%)

4. **데이터 보존 전략**: 필요 시 PVC 추가 고려
   - MinIO, Nessie, PostgreSQL 등 선택적 persistence 활성화

## 📚 참고 문서
- 프로젝트 개요: `./overview.md`
- AI 작업 가이드: `./CLAUDE.md`
- 실전 패턴: `~/.claude/projects/-Users-smylere-work-etl-platform/memory/MEMORY.md`

## 🔄 최근 커밋 히스토리
```
99dc9ca feat: Add selective component deployment to manage-project.sh
3b24430 docs: update handoff documentation
4882be2 feat: Rename Spark SQL catalog from nessie to iceberg
f82ab24 feat: Dependency-ordered startup in manage-project.sh
8016869 fix: Harden init_data.sh with all discovered issues resolved
```

---
*본 문서는 Claude Code에 의해 2026-03-21 세션 종료 시점에 작성되었습니다.*
