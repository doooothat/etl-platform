# 🤝 AI Agent Handoff (Finalized Session)

이 문서는 세션 종료 시점의 프로젝트 상태와 다음 작업자를 위한 가이드를 담고 있습니다.

## 🕒 마지막 업데이트
- **일시**: 2026-04-03T22:35:00+09:00
- **에이전트**: Antigravity (Google Deepmind)
- **상태**: 기존 시스템 완벽 구동 확인 완료 및 프로메테우스+그라파나(경량화) 생태계 통합 추가

## 🛠️ 금일 작업 완료 사항

### 1. Superset - Trino(Iceberg) 연동 완벽 해결
- **문제점**: Superset에서 Trino를 통해 Iceberg 카탈로그 테이블을 조회하지 못하는 문제.
- **해결 내역**:
  - `manage-project.sh`에서 트리노 배포 시 공식 헬름 차트(`trino/trino`)를 잘못 바라보는 이슈 수정 → 로컬 차트 경로(`./trino`)로 바로잡음.
  - Nessie 0.107.0 버전의 REST Catalog 엔드포인트 변경에 맞춰 `trino/templates/configmap.yaml` 안의 `iceberg.rest-catalog.uri` 주소를 `/api/v1/iceberg/main`에서 `/iceberg/main`으로 수정 완료.
  - 현재 Superset의 SQL Lab에서 `ecommerce.customers` 테이블 등 데이터를 성공적으로 쿼리 가능 (데이터 15건 렌더링 확인).

### 2. manage-project.sh 스크립트 결함 수정 및 고도화
- **PVC 완벽 파괴 방침 적용**: 개발 환경 보호 및 휘발성 강화를 위해 `stop` 실행 시, 존재하는 모든 PVC와 PV를 무조건 삭제하도록 스크립트 수정.
- **scale_ns 오류 해결**: 내부적으로 StatefulSet을 0으로 스케일다운 시 다운되지 않고 남아있던 버그 해결 (API 통신 `--timeout=5s` 강제 대기 조건 제거).
- **에이전트 좀비 현상 원천 차단 (Airflow Redis 이슈)**:
  - 기존의 `kubectl delete pod --force` 구문이 쿠버네티스에는 파드를 즉시 없애지만, 컨테이너 런타임(OrbStack) 단에는 Orphan(좀비) 찌꺼기를 남기는 현상을 확인.
  - 이를 해결하기 위해 `stop` 로직에서 해당 파드와 PVC들의 지독한 족쇄인 `finalizers`만 `null`로 조용히 지워준 후, 런타임 엔진이 우아하게(Gracefully) 파드를 자체 종료할 수 있도록 스크립트 리팩토링 및 강제종료 제거 완료.
  - 이미 남겨진 좀비 컨테이너는 호스트 도커를 통해 `docker rm -f`로 수동 박멸함.
- **Spark Operator 버전 락인(Pin)**: `deploy` 수행 시 버전을 명시하지 않아, 버그가 있는 2.4.0이 재설치되며 과거의 CrashLoopBackOff에 빠지던 문제를 방지하기 위해 헬름 배포 구문에 `--version 2.3.0`을 하드코딩함.

### 3. 모니터링 스택(Prometheus + Grafana) 추가 적용 구축 (2026-04-03)
- **로컬 최적화(경량화) 버전 배포**: OrbStack의 유휴 자원(잔여 가용 RAM ~4GB)을 고려하여 `kube-prometheus-stack`을 극히 가벼운 버전으로 재설계.
  - `custom-values.yaml` 작성 (`monitoring` 디렉토리 내).
  - AlertManager, NodeExporter 사용 중지 및 Prometheus Storage 1Day(In-Memory) 유지.
- **포트 충돌 및 로컬 매핑 대응**: Grafana 접속 설정을 고도화하여 포트 80 대신 `3000`번 포트에서 `LoadBalancer` 방식으로 즉각적으로 노출 완료(`http://localhost:3000` / admin : admin).
- **자동 기동 스크립트 연동 완료**: `manage-project.sh`의 Deploy & Start 로직(Stage 6)에 가장 마지막으로 Grafana가 기동되도록 통합 완료.

## 📊 현재 시스템 상태

### 실행 중인 서비스 (All Running)
모든 컴포넌트 오류가 해결된 것을 넘어선 상태로, 사용자에 의해 `manage-project.sh start` 명령을 통해 모든 워크포스가 완벽한 의존성 구조를 기반으로 Full 구동 중입니다. (Airflow, Superset, Trino, MinIO, Spark Operator, 그리고 Prometheus + Grafana 까지 모두 레디스 상태 확인됨)

### 주요 인프라 특성
- **데이터 휘발성**: 모든 DB/Storage는 `persistence.enabled: false` (ephemeral)이며 스크립트 단에서도 PVC를 영구적으로 박멸합니다.
- **Nessie Catalog**: `IN_MEMORY` (pod 재시작 시 초기화 필요)
- **Airflow DAGs**: `hostPath` mount → teardown 시에도 보존
- **MinIO**: Standalone mode, `iceberg-data` bucket 자동 생성

## 🔧 주요 운영 명령어

```bash
# 상태 확인
./manage-project.sh status

# 전체 중지/시작
./manage-project.sh stop   # 파드 0, PVC/PV 클리어 및 Finalizer 정리 적용됨
./manage-project.sh start  # KEDA 등 의존관계 기반 순차적 클러스터 풀 기동 및 마이그레이션

# 개별 컴포넌트 재배포
./manage-project.sh deploy nessie
./manage-project.sh deploy spark-operator

# 전체 재설치
./manage-project.sh deploy          # 확인 프롬프트 표시
./init_data.sh                      # 데이터 초기화 (통상 start 내에 포함됨)

# OrbStack 전체 종료
./manage-project.sh shutdown
```

## ⚠️ 알려진 이슈(수정 완료)

과거 보고되었던 주요 이슈들은 오늘자 작업으로 `manage-project.sh` 스크립트 단에서 원천 차단되도록 설계가 완료되었습니다. 아래 조치는 참고용 보존 기록입니다:

1. **Spark Operator CrashLoopBackOff**: Helm 파라미터에 `>=2.4.0` 플래그 미지원 문제로 고질적 에러가 나던 현상은 스크립트 배포 시점에서 `v2.3.0`으로 릴리즈 버전을 영구 고정하여 해결했습니다.
2. **Airflow Namespace Terminating 멈춤**: Airflow-redis 파드와 PVC들이 Finalizer로 인해 영원히 Terminating 상태에 빠지던 문제를 회피하기 위해 `manage-project.sh stop` 시 `finalizers: null` 패치만 신속히 진행하는 로직을 심어둬서 수동 조작이 불필요해졌습니다.

## 📝 다음 세션 작업 제안

1. **파이프라인 구축 시작**: 모든 ETL 베이스라인과 모니터링 컴포넌트까지 완벽하게 기동 중입니다! 다음 세션부터는 Airflow DAG를 통한 데이터 적재/집계 파이프라인(ETL)을 실질적으로 개발해볼 수 있습니다.
2. **Superset 메인 대시보드 기획**: Airflow가 가공한 Iceberg 테이블 통계를 Trino를 통해 Superset에서 어떻게 구성할지 대시보드 작성을 시작해보면 좋습니다.
3. **Unity Catalog OSS(Databricks 버전) 도입 검토**: 오늘 세션 초반에 검토한대로, 2026년 최신 트렌드인 Databricks의 `Delta Lake 4.x + Unity Catalog OSS` 스택으로의 변경(마이그레이션) POC 구성을 진행해볼 수도 있습니다!

---
*본 문서는 Antigravity 에 의해 2026-04-03 세션 종료 시점에 최신화되어 기록되었습니다.*
