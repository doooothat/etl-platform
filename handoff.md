# 🤝 AI Agent Handoff (Finalized Session)

이 문서는 세션 종료 시점의 프로젝트 상태와 다음 작업자를 위한 가이드를 담고 있습니다.

## 🕒 마지막 업데이트
- **일시**: 2026-03-22T00:50:00+09:00
- **에이전트**: Antigravity (Google Deepmind)
- **상태**: Trino-Nessie 연동 문제 완벽 해결 및 manage-project.sh 셧다운(Stop) 로직 고도화

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

## 📊 현재 시스템 상태

### 실행 중인 서비스 (All Stopped)
현재 모든 워크로드는 사용자의 명령(`stop`)에 의해 **레플리카 0(또는 완전 삭제)**로 클린하게 내려진 상태이며, 볼륨조차 소멸된 깨끗한 `Zero State`입니다. 작업 재개 시 `./manage-project.sh start` 명령을 입력하면 모든 데이터가 샘플링되고 시스템이 완벽한 의존성 순서대로 재기동됩니다.

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

1. **파이프라인 구축 시작**: 모든 컴포넌트 오류가 해결되고 트리노 조회까지 연동이 완료되었습니다! 다음 세션부터는 곧바로 Airflow DAG를 통한 데이터 적재 처리를 개발하시면 됩니다.
2. **Superset 메인 대시보드 기획**: Airflow가 쏴주는 고객 정보를 연동 받아 실시간 차트를 구성하는 것을 권장합니다.
3. PVC가 강제로 사라지게 된 점을 인지하시고, 다음 세션에서 영구 보존이 필요한 저장소 설계가 논의될 경우 `stateful`로 정책을 일부 토글하세요.

---
*본 문서는 Antigravity 에 의해 2026-03-22 세션 종료 시점에 최신화되어 기록되었습니다.*
