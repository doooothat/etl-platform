# [Study] Kafka Infrastructure Troubleshooting (Detailed Case Study)
**날짜:** 2026-04-20
**환경:** macOS 15.1 (M4 Apple Silicon), OrbStack (K8s v1.31.1), Apache Kafka 3.9.0 (KRaft)

## 1. 개요
로컬 Kubernetes 환경에 메시지 버스인 Kafka를 구축하면서 발생한 **이미지 호환성, Helm 차트 구성 오류, 이미지 내부 래퍼 스크립트의 설정 간섭** 문제를 분석하고 최종 성공에 이른 과정을 상세히 기록한다.

---

## 2. Phase 1: Bitnami Helm Chart와 이미지 잔혹사
### 2.1 사건의 발단
- **목표:** Bitnami Kafka Helm 차트를 사용하여 표준적인 Kafka 클러스터 구축.
- **시도:** `bitnami/kafka` 최신 차트 사용.

### 2.2 장애 발생: "Image Pull BackOff"
- **현상:** Docker Hub에서 Bitnami 이미지를 가져오지 못함.
- **원인 분석:** Bitnami가 최근 Docker Hub 정책 변화로 인해 무료 풀을 제한하거나 특정 레지스트리로 이관됨.
- **우회 전략:** `bitnamilegacy/kafka:3.7.1` 이미지로 선회. (ARM64 레이어가 포함된 안정적인 버전 탐색)

### 2.3 장애 발생: "ConfigException: Quorum Voters Parsing Error"
- **현상:** 환경 변수를 넣었음에도 `controller.quorum.voters`를 파싱할 수 없다는 에러 발생.
- **Aha-Moment:** 포드 설정을 뜯어보니(kubectl get pod -o yaml) 우리가 넣은 `extraEnvVars`가 아예 보이지 않음.
- **실수 분석:** Bitnami 차트 최신 버전은 `controller`와 `broker`가 분리되어 있어, `extraEnvVars`를 **루트 레벨**에 넣으면 무시됨. 반드시 `controller.extraEnvVars` 아래에 배치해야 함.

---

## 3. Phase 2: Bitnami Legacy 이미지의 한계점 발견
### 3.1 사건 상황
- 환경 변수 주입은 성공했으나, 여전히 같은 파싱 에러 발생.
- `0@kafka-controller-0.kafka-controller-headless.kafka.svc.cluster.local:9093` 주소를 비트나미 초기화 스크립트가 로드하지 못함.

### 3.2 분석 및 결론
- **레거시 이미지의 결함:** `bitnamilegacy` 이미지는 특정 KRaft 설정 조합에서 내부 배시 스크립트가 특수문자(`@`, `.`)가 포함된 주소를 처리할 때 따옴표 처리가 미흡하거나 환경 변수 우선순위가 꼬이는 현상 발견.
- **전략 수정:** "Helm 차트가 너무 복잡하게 꼬여있다. 차라리 순수하고 명확한 **Apache 공식 이미지**로 갈아엎자."

---

## 4. Phase 3: Apache 공식 이미지와 래퍼 스크립트의 사투
### 4.1 1차 시도: "Routable Address" 에러
- **설정:** `KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092`
- **에러:** `advertised.listeners cannot use the nonroutable meta-address 0.0.0.0`
- **분석:** Apache 공식 이미지는 실행 시 전처리 스크립트(`/etc/kafka/docker/run`)가 돌아감. 이 스크립트가 `ADVERTISED_LISTENERS`에 `0.0.0.0`이 포함되는 것을 강제로 막고 있음.

### 4.2 2차 시도: "BindException"
- **설정:** `KAFKA_LISTENERS`에 DNS 이름(`kafka.kafka.svc...`) 입력.
- **에러:** `Address not available`.
- **분석:** 리스너는 실제 소켓을 여는 "Bind" 용도이므로 DNS 이름을 사용할 수 없고 IP나 `0.0.0.0`이어야 함.

### 4.3 3차 시도: "Controller Listener Missing"
- **설정:** `KAFKA_LISTENERS`를 수동으로 0.0.0.0으로 주되, `ADVERTISED`는 DNS로 분리.
- **에러:** `controller.listener.names must contain at least one value appearing in the 'listeners' configuration`.
- **Aha-Moment (Internal Script Analysis):**
    - 이미지 내부의 `/etc/kafka/docker/configure` 스크립트를 직접 `cat`으로 뜯어봄.
    - **발견한 핵심 로직:**
      ```bash
      if [[ -z "${KAFKA_LISTENERS-}" ]] ...
      then
        KAFKA_LISTENERS=$(echo "$KAFKA_ADVERTISED_LISTENERS" | sed -e 's|://[^:]*:|://0.0.0.0:|g')
      fi
      ```
    - 즉, **`KAFKA_LISTENERS`를 우리가 수동으로 설정하면 안 됨!** 비워두어야 이미지가 `ADVERTISED_LISTENERS`를 기반으로 똑똑하게 `0.0.0.0` 바인딩 주소를 생성해줌.

---

## 5. 최종 해결: 황금 조합 도출
### 5.1 최종 성공 설정 (Kubectl Manifest)
```yaml
env:
  - name: KAFKA_PROCESS_ROLES
    value: "broker,controller"
  - name: KAFKA_CONTROLLER_QUORUM_VOTERS
    value: "1@kafka-0.kafka-headless.kafka.svc.cluster.local:9093"
  # ✅ 핵심: LISTENERS는 아예 생략 (자동 파생 유도)
  # ✅ 핵심: ADVERTISED_LISTENERS에 브로커(9092)와 컨트롤러(9093) 주소를 모두 포함
  - name: KAFKA_ADVERTISED_LISTENERS
    value: "PLAINTEXT://kafka-0.kafka-headless.kafka.svc.cluster.local:9092,CONTROLLER://kafka-0.kafka-headless.kafka.svc.cluster.local:9093"
  - name: KAFKA_CONTROLLER_LISTENER_NAMES
    value: "CONTROLLER"
```

### 5.2 결과 및 검증
- **Kafka Node:** `READY 1/1`, `STATUS Running`
- **로그:** `[KafkaRaftServer nodeId=1] Kafka Server started` 확인.
- **Kafka UI:** 브로커와 정상 연결 및 토픽 브라우징 성공.

---

## 6. 최종 정리 및 교훈
1.  **이미지 내부를 의심하라:** 공식 이미지라고 해서 무조건 환경 변수를 직관적으로 처리하지 않는다. 이번처럼 래퍼 스크립트가 값을 가공하거나 검증하는 로직이 있다면 이를 먼저 이해해야 한다.
2.  **Explicit vs Implicit:** 때로는 모든 값을 명시적으로(Explicit) 적어주는 것보다, 도구의 자동화 로직(Implicit)이 작동하도록 변수를 비워두는 것이 정답일 수 있다. (`KAFKA_LISTENERS` 사례)
3.  **StatefulSet의 안정성:** KRaft 모드에서 Quorum 투표자 주소는 반드시 고정되어야 하므로, 일반 Deployment가 아닌 StatefulSet + Headless Service의 조합이 필수적이다.

---

## 7. 인프라 메타데이터
- **Kafka UI Port:** 9080 (Localhost)
- **Kafka Broker Port:** 9092 (External LoadBalancer)
- **Retention Strategy:** FIFO (최대 500MB / 2시간 생존 정책 적용 완료)
