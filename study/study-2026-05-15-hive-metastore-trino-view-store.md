# [Study] Hive Metastore + Trino View Store Integration
**날짜:** 2026-05-15  
**환경:** macOS, OrbStack Kubernetes, Apache Hive Metastore 4.0.0, Trino 480, Spark 4.0.2, Nessie, Iceberg, MinIO, Airflow PostgreSQL

## 1. 개요
이번 작업의 목표는 기존 Lakehouse 경로인 **Trino/Spark -> Iceberg -> Nessie -> MinIO** 흐름은 그대로 유지하면서, Trino에서 생성한 view 메타데이터를 저장하고 공유할 별도 메타스토어 레이어를 추가하는 것이었다.

기존 구조에서는 Iceberg table metadata는 Nessie REST catalog가 담당한다. 이 방식은 Iceberg table에는 적합하지만, 사용자가 Trino에서 만든 논리 view를 안정적으로 저장하고 나중에 다시 조회하려면 별도 catalog/metastore가 필요하다. 따라서 Hive Metastore를 추가하고, Trino에 `hive` catalog를 붙여 **Trino view store**처럼 사용하는 구조를 만들었다.

최종 목표는 다음과 같다.

```text
Trino
  ├─ iceberg.ecommerce.*  -> Nessie REST catalog -> MinIO Iceberg data
  └─ hive.shared.*        -> Hive Metastore -> Trino-created views

Spark Thrift Server
  └─ Hive Metastore 연결 확인 및 Spark/Hive 호환성 smoke test
```

작업 결과, OrbStack 클러스터에서 다음 상태까지 검증했다.

- `hive-metastore`: `1/1 Running`
- `trino`: `1/1 Running`, version `480`
- `spark-thrift-server`: `1/1 Running`
- 비정상 pod 없음
- Trino `SHOW CATALOGS`에 `hive`, `iceberg`, `iceberg_dev` 모두 표시
- 기존 Iceberg sample data 조회 정상
  - `iceberg.ecommerce.customers`: 15 rows
  - `iceberg.ecommerce.products`: 14 rows
  - `iceberg.ecommerce.orders`: 20 rows
- Trino에서 Hive catalog view를 만들고 조회할 수 있는 상태 확인

---

## 2. 작업 전 상태와 문제 인식

### 2.1 기존 정상 동작 범위
작업 전에도 기본 Lakehouse path는 살아 있었다.

```bash
kubectl exec -n trino deploy/trino -- trino --catalog iceberg --schema ecommerce --execute "SHOW TABLES"
```

결과:

```text
"customers"
"orders"
"products"
```

또한 Spark sample job도 완료된 상태였다.

```bash
kubectl get sparkapplication -n spark iceberg-nessie-restore \
  -o jsonpath='{.status.applicationState.state}{"\n"}'
```

결과:

```text
COMPLETED
```

즉 문제는 Iceberg/Nessie/MinIO가 아니라, 새로 추가하려는 Hive Metastore와 Trino Hive catalog 연결부에 있었다.

### 2.2 최초 Hive Metastore 상태
처음 클러스터 상태를 확인했을 때 Hive Metastore는 Helm release는 존재했지만 pod는 정상 기동하지 못했다.

```bash
kubectl get pods -n hive-metastore
```

대표 증상:

```text
hive-metastore-...   0/1   CrashLoopBackOff
hive-metastore-...   0/1   Init:CrashLoopBackOff
```

이벤트에서는 여러 번의 이미지/초기화 실패가 섞여 있었다.

- `ghcr.io/getindata/hive-metastore:3.1.2`: unauthorized
- `bitsondatadev/hive-metastore:3.1.2`: manifest not found
- `apache/hive:4.0.0`: image pull은 성공했지만 runtime에서 실패
- `curlimages/curl`: initContainer command path 문제

처음부터 하나의 문제가 아니라, 이미지 선택, JDBC driver 준비, DB 준비 순서, Trino catalog mount가 서로 얽혀 있었다.

---

## 3. 설계 의도 정리

이번 Hive Metastore는 Iceberg table catalog를 대체하기 위한 것이 아니다.

역할 분리는 다음과 같이 잡았다.

| Catalog | 역할 |
| :--- | :--- |
| `iceberg` | Nessie `main` branch를 보는 Iceberg table catalog |
| `iceberg_dev` | Nessie `dev` branch를 보는 개발용 Iceberg catalog |
| `hive` | Hive Metastore를 사용하는 Trino view/catalog 저장소 |

즉 실제 원본 데이터는 계속 다음 경로로 조회한다.

```sql
SELECT * FROM iceberg.ecommerce.customers;
```

Trino에서 작성하는 재사용 view는 다음처럼 Hive catalog에 둔다.

```sql
CREATE SCHEMA IF NOT EXISTS hive.shared;

CREATE OR REPLACE VIEW hive.shared.customer_summary AS
SELECT country, count(*) AS customer_count
FROM iceberg.ecommerce.customers
GROUP BY country;
```

이렇게 하면 view definition은 Hive Metastore에 저장되고, view가 참조하는 실제 데이터는 Iceberg/Nessie catalog를 통해 읽힌다.

---

## 4. 수정 파일 요약

### 4.1 신규 Hive Metastore chart
추가된 파일:

```text
hive-metastore/Chart.yaml
hive-metastore/values.yaml
hive-metastore/templates/deployment.yaml
```

핵심 설정:

- image: `apache/hive:4.0.0`
- metastore DB: Airflow PostgreSQL 안의 `metastore` database
- JDBC driver: initContainer에서 PostgreSQL JDBC jar 다운로드 후 Hive container에 mount
- warehouse dir: `file:/tmp/hive/warehouse`
- service port: `9083`

### 4.2 `manage-project.sh`
변경 내용:

- `RELEASES`에 `hive-metastore` 추가
- `NAMESPACES`에 `hive-metastore` 추가
- `ensure_hive_metastore_db()` 추가
- full start 시 Airflow PostgreSQL statefulset을 먼저 올리고 `metastore` DB를 보장한 뒤 Hive Metastore 시작
- `./manage-project.sh` 인자 없이 실행 시 `$1: unbound variable`이 나던 문제 수정

### 4.3 Trino chart
변경 내용:

- `catalog-hive.properties` 추가
- `hive` catalog를 `/etc/trino/catalog/hive.properties`로 실제 mount
- Trino 480 기준 S3 설정은 `fs.native-s3.enabled=true`와 `s3.*` 속성 사용
- Hive view 읽기를 위해 `hive.hive-views.enabled=true` 추가

### 4.4 Spark Thrift Server
변경 내용:

- Spark SQL catalog implementation을 Hive로 설정
- Hive Metastore URI 추가
- warehouse dir을 `file:/tmp/hive/warehouse`로 설정
- Spark runtime에 `org.apache.hadoop:hadoop-aws:3.4.1` 추가

---

## 5. 장애와 해결 과정

### 5.1 장애 1: Hive Metastore image pull 실패

### 현상
초기 이벤트에 다음 이미지 pull 실패가 있었다.

```text
Failed to pull image "ghcr.io/getindata/hive-metastore:3.1.2": unauthorized
Failed to pull image "bitsondatadev/hive-metastore:3.1.2": manifest not found
```

### 원인
처음 시도했던 third-party Hive Metastore 이미지들이 private이거나 태그가 존재하지 않았다. 또한 chart metadata의 `appVersion`은 `3.1.2`였지만 실제로 사용하려는 image는 `apache/hive:4.0.0`이라 버전 의도도 섞여 있었다.

### 해결
공식 `apache/hive:4.0.0` 이미지를 사용하도록 정리했다.

```yaml
image:
  repository: apache/hive
  tag: "4.0.0"
```

그리고 `Chart.yaml`의 `appVersion`도 `4.0.0`으로 맞췄다.

```yaml
appVersion: "4.0.0"
```

---

### 5.2 장애 2: PostgreSQL JDBC driver 없음

### 현상
`apache/hive:4.0.0` 컨테이너는 뜨기 시작했지만 schema init 단계에서 실패했다.

대표 로그:

```text
Metastore connection URL: jdbc:postgresql://airflow-postgresql.airflow.svc.cluster.local:5432/metastore
Failed to load driver
Underlying cause: java.lang.ClassNotFoundException : org.postgresql.Driver
Schema initialization failed!
```

### 원인
Hive 공식 이미지에는 PostgreSQL JDBC driver가 기본 포함되어 있지 않았다. `SERVICE_OPTS`에 `org.postgresql.Driver`를 지정해도 실제 jar가 classpath에 없으면 schema init이 실패한다.

### 해결
initContainer에서 PostgreSQL JDBC jar를 다운로드하고, Hive container의 `/opt/hive/lib/postgresql-jdbc.jar`로 mount하도록 구성했다.

```yaml
- name: download-driver
  image: "{{ .Values.postgresqlClient.repository }}:{{ .Values.postgresqlClient.tag }}"
  command:
    ["sh", "-ec", "curl -fsSL https://jdbc.postgresql.org/download/postgresql-42.7.3.jar -o /work/postgresql-jdbc.jar && test -s /work/postgresql-jdbc.jar"]
  volumeMounts:
    - name: lib-vol
      mountPath: /work
```

```yaml
volumeMounts:
  - name: lib-vol
    mountPath: /opt/hive/lib/postgresql-jdbc.jar
    subPath: postgresql-jdbc.jar
```

---

### 5.3 장애 3: initContainer shell 실행 실패

### 현상 A: `curlimages/curl`
처음에는 `curlimages/curl`로 driver를 다운로드하려고 했는데 다음처럼 실패했다.

```text
exec /usr/bin/curl: no such file or directory
```

### 현상 B: `busybox`
그 다음 `busybox`로 바꾸었지만 다음 문제가 발생했다.

```text
exec /bin/sh: no such file or directory
```

### 현상 C: `bitnami/postgresql`
DB init에 이미 쓰던 `bitnami/postgresql` 이미지를 downloader에도 사용했는데, 처음에는 다음처럼 실패했다.

```text
exec /usr/bin/bash: no such file or directory
exec /usr/bin/sh: no such file or directory
```

### 원인
결정적인 원인은 volume mount 위치였다.

초기에는 driver 공유용 `emptyDir`를 `/lib`에 mount했다. 그런데 `/lib`는 Linux runtime loader와 shell 실행에 필요한 시스템 라이브러리가 있는 경로다. 여기에 빈 볼륨을 mount하면서 이미지 내부의 필수 라이브러리를 가려버렸고, 그 결과 shell이나 command가 존재하지 않는 것처럼 실패했다.

### 해결
download initContainer의 mount path를 시스템 경로가 아닌 `/work`로 변경했다.

잘못된 방식:

```yaml
mountPath: /lib
```

최종 방식:

```yaml
mountPath: /work
```

이후 다운로드한 파일만 `subPath`로 Hive container에 mount했다.

---

### 5.4 장애 4: Metastore DB 준비 순서 문제

### 현상
Hive Metastore는 Airflow PostgreSQL의 `metastore` database를 보도록 설정되어 있었다.

```yaml
database:
  host: airflow-postgresql.airflow.svc.cluster.local
  user: airflow
  password: airflow
  name: metastore
```

하지만 Airflow chart는 기본적으로 `airflow` database만 생성한다.

```yaml
postgresql:
  auth:
    username: airflow
    password: airflow
    database: airflow
```

게다가 full start 순서에서는 Hive Metastore가 Airflow PostgreSQL보다 먼저 시작될 수 있는 위치에 있었다.

### 원인
Hive Metastore는 `metastore` DB가 있어야 schema init을 할 수 있다. 하지만 DB 생성과 statefulset 준비가 lifecycle script에서 보장되지 않았다.

### 해결
`manage-project.sh`에 `ensure_hive_metastore_db()`를 추가했다.

```bash
function ensure_hive_metastore_db() {
    wait_statefulset airflow airflow-postgresql 120
    log_wait "Ensuring Hive Metastore database exists in Airflow PostgreSQL..."
    kubectl exec -n airflow airflow-postgresql-0 -- bash -lc \
        "PGPASSWORD=airflow psql -U airflow -d airflow -tAc \"SELECT 1 FROM pg_database WHERE datname='metastore'\" | grep -q 1 || PGPASSWORD=airflow createdb -U airflow metastore" \
        && log_ok "Hive Metastore database is ready." \
        || log_err "Could not prepare Hive Metastore database."
}
```

full start에서는 Hive Metastore stage 전에 Airflow PostgreSQL만 먼저 올린다.

```bash
scale_ns airflow 1 statefulsets
ensure_hive_metastore_db
scale_ns hive-metastore 1
wait_deploy hive-metastore hive-metastore 120
```

Hive Metastore chart 내부에도 `init-metastore-db` initContainer를 두어 chart 단독 배포 시에도 DB 생성을 보장했다.

---

### 5.5 장애 5: Trino Hive catalog가 ConfigMap에만 있고 실제 mount되지 않음

### 현상
로컬 소스에는 `catalog-hive.properties`가 추가되어 있었지만, Trino deployment에는 다음 두 catalog만 mount되어 있었다.

```yaml
/etc/trino/catalog/iceberg.properties
/etc/trino/catalog/iceberg_dev.properties
```

따라서 Trino에서 catalog 목록을 확인하면 `hive`가 보이지 않았다.

```sql
SHOW CATALOGS;
```

결과:

```text
"iceberg"
"iceberg_dev"
"jmx"
"memory"
"system"
"tpcds"
"tpch"
```

### 원인
Trino는 `/etc/trino/catalog/*.properties` 파일 단위로 catalog를 로딩한다. ConfigMap에 key가 존재하는 것만으로는 catalog가 생성되지 않는다. 반드시 container filesystem에 mount되어야 한다.

### 해결
`trino/templates/deployment.yaml`에 mount를 추가했다.

```yaml
- name: catalog
  mountPath: /etc/trino/catalog/hive.properties
  subPath: catalog-hive.properties
```

재배포 후 `SHOW CATALOGS` 결과:

```text
"hive"
"iceberg"
"iceberg_dev"
"jmx"
"memory"
"system"
"tpcds"
"tpch"
```

---

### 5.6 장애 6: Trino 480의 S3 설정 키 정리

### 현상
초기 Hive catalog 설정은 다음처럼 `hive.s3.*` 계열을 사용했다.

```properties
hive.s3.endpoint=...
hive.s3.aws-access-key=...
hive.s3.aws-secret-key=...
hive.s3.path-style-access=true
```

### 원인
현재 Trino chart는 `trino/values.yaml` 기준 `trinodb/trino:480`을 사용한다. 기존 Iceberg catalog는 이미 Trino native S3 filesystem 형식인 `fs.native-s3.enabled=true`와 `s3.*` 속성을 쓰고 있었다.

같은 Trino 버전에서 Hive catalog도 같은 S3 설정 방식으로 맞추는 것이 안전하다.

### 해결
Hive catalog를 다음 형태로 정리했다.

```properties
connector.name=hive
hive.metastore.uri=thrift://hive-metastore.hive-metastore.svc.cluster.local:9083
fs.native-s3.enabled=true
s3.endpoint=http://minio.minio.svc.cluster.local:9000
s3.aws-access-key=admin
s3.aws-secret-key=password
s3.path-style-access=true
s3.region=us-east-1
hive.storage-format=PARQUET
hive.hive-views.enabled=true
```

`hive.hive-views.enabled=true`는 Spark/Hive style view 조회 가능성을 위해 추가했다. 다만 이번 작업의 사용 시나리오 중심은 Trino-created view이므로, 실제 운영 테스트는 Trino에서 view를 만들고 Trino에서 읽는 방식으로 진행한다.

---

### 5.7 장애 7: Spark Thrift Server와 S3A warehouse 문제

### 현상
처음 Spark Thrift Server에 Hive Metastore를 붙이면서 warehouse를 `s3a://iceberg-data/hive/warehouse`로 설정했다.

```properties
spark.sql.warehouse.dir=s3a://iceberg-data/hive/warehouse
```

Spark Thrift Server는 기동했지만 로그에 다음 경고/예외가 남았다.

```text
java.lang.ClassNotFoundException: Class org.apache.hadoop.fs.s3a.S3AFileSystem not found
```

이후 Spark Thrift Server에서 database/view를 만들려고 하자 Hive Metastore server 쪽에서도 같은 문제가 발생했다.

```text
MetaException(message:java.lang.RuntimeException:
java.lang.ClassNotFoundException: Class org.apache.hadoop.fs.s3a.S3AFileSystem not found)
```

### 원인
문제가 두 겹이었다.

첫째, Spark runtime에 `hadoop-aws` jar가 없어 `s3a://` path를 완전히 처리하지 못했다.

둘째, 더 중요한 점은 Hive Metastore server 자체도 database location을 검증하면서 `s3a://` filesystem class를 필요로 했다. 그런데 Hive Metastore image에는 S3A 관련 jar 구성이 충분하지 않았다.

### 해결 1: Spark runtime 보강
Spark Thrift Server의 `--packages`에 Hadoop AWS jar를 추가했다.

```yaml
--packages
org.apache.iceberg:iceberg-spark-runtime-4.0_2.13:1.10.1,
org.apache.iceberg:iceberg-aws-bundle:1.10.1,
org.apache.hadoop:hadoop-aws:3.4.1
```

### 해결 2: Hive view store warehouse를 local path로 낮춤
이번 Hive Metastore의 주 목적은 실제 Hive managed table 저장소가 아니라 **view metadata store**다. 실제 데이터는 계속 Iceberg/Nessie/MinIO에 있다. 따라서 Hive warehouse를 S3A로 강제할 필요가 없었다.

최종 설정:

```yaml
s3:
  warehouseDir: "file:/tmp/hive/warehouse"
```

Spark Thrift Server도 동일하게 맞췄다.

```properties
spark.sql.warehouse.dir=file:/tmp/hive/warehouse
```

이후 Spark Thrift Server 로그에서 `S3AFileSystem` class error가 사라졌고, Hive Metastore 연결도 정상화됐다.

---

### 5.8 장애 8: `manage-project.sh` 인자 없는 실행 실패

### 현상
다음 명령을 실행하면 usage가 아니라 `$1: unbound variable`로 실패했다.

```bash
./manage-project.sh
```

### 원인
스크립트 상단에 `set -euo pipefail`이 있고, main case 문이 `case "$1" in` 형태였다. 인자 없이 실행하면 `-u` 옵션 때문에 `$1` 참조가 에러가 된다.

### 해결
다음처럼 기본값을 넣었다.

```bash
case "${1:-}" in
```

수정 후에는 usage가 정상 출력된다.

```text
Usage: ./manage-project.sh {start|stop|status|deploy [name]|shutdown}
```

---

## 6. 최종 배포 순서

실제 안정화 과정에서 사용한 큰 흐름은 다음과 같다.

### 6.1 Airflow PostgreSQL DB 준비

```bash
kubectl scale statefulset airflow-postgresql -n airflow --replicas=1
kubectl rollout status statefulset/airflow-postgresql -n airflow --timeout=180s
kubectl exec -n airflow airflow-postgresql-0 -- bash -lc \
  "PGPASSWORD=airflow psql -U airflow -d airflow -tAc \"SELECT 1 FROM pg_database WHERE datname='metastore'\" | grep -q 1 || PGPASSWORD=airflow createdb -U airflow metastore"
```

### 6.2 Hive Metastore 재배포

```bash
helm upgrade --install hive-metastore ./hive-metastore \
  -n hive-metastore \
  --create-namespace \
  -f ./hive-metastore/values.yaml

kubectl rollout status deployment/hive-metastore \
  -n hive-metastore \
  --timeout=240s
```

### 6.3 Trino 재배포

```bash
helm upgrade --install trino ./trino \
  -n trino \
  -f ./trino/values.yaml

kubectl rollout status deployment/trino \
  -n trino \
  --timeout=240s
```

### 6.4 Spark Thrift Server 재적용

```bash
kubectl apply -f ./spark/spark-thrift-server.yaml

kubectl rollout status deployment/spark-thrift-server \
  -n spark \
  --timeout=300s
```

---

## 7. 최종 검증

### 7.1 Pod 상태

```bash
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

결과:

```text
No resources found
```

핵심 deployment:

```bash
kubectl get deploy -n hive-metastore
kubectl get deploy -n trino
kubectl get deploy -n spark spark-thrift-server
```

결과:

```text
hive-metastore       1/1
trino                1/1
spark-thrift-server  1/1
```

### 7.2 Hive Metastore schema init 성공

```bash
kubectl logs -n hive-metastore deploy/hive-metastore --tail=120
```

핵심 로그:

```text
Initialization script completed
Initialized schema successfully..
Starting Hive Metastore Server
```

### 7.3 Spark Thrift Server가 Hive Metastore에 연결

```bash
kubectl logs -n spark deploy/spark-thrift-server --tail=80
```

핵심 로그:

```text
Trying to connect to metastore with URI thrift://hive-metastore.hive-metastore.svc.cluster.local:9083
Opened a connection to metastore
Connected to metastore.
HiveThriftServer2 started
```

### 7.4 Trino catalog 확인

```bash
kubectl exec -n trino deploy/trino -- trino --execute "SHOW CATALOGS"
```

결과:

```text
"hive"
"iceberg"
"iceberg_dev"
"jmx"
"memory"
"system"
"tpcds"
"tpch"
```

### 7.5 기존 Iceberg 데이터 확인

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
SELECT count(*) FROM iceberg.ecommerce.customers;
SELECT count(*) FROM iceberg.ecommerce.products;
SELECT count(*) FROM iceberg.ecommerce.orders;
"
```

결과:

```text
"15"
"14"
"20"
```

### 7.6 Spark -> HMS -> Trino smoke test

Spark Thrift Server에서 Hive Metastore에 view를 만들었다.

```bash
kubectl exec -n spark deploy/spark-thrift-server -- \
  /opt/spark/bin/beeline -u jdbc:hive2://localhost:10000 \
  -e "CREATE DATABASE IF NOT EXISTS shared; CREATE OR REPLACE VIEW shared.smoke_view AS SELECT 1 AS ok;"
```

Trino에서 Hive catalog를 통해 조회했다.

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
SHOW SCHEMAS FROM hive;
SHOW TABLES FROM hive.shared;
SELECT * FROM hive.shared.smoke_view;
"
```

결과:

```text
"default"
"information_schema"
"shared"
"smoke_view"
"1"
```

테스트 후 정리:

```bash
kubectl exec -n spark deploy/spark-thrift-server -- \
  /opt/spark/bin/beeline -u jdbc:hive2://localhost:10000 \
  -e "DROP VIEW IF EXISTS shared.smoke_view; DROP DATABASE IF EXISTS shared;"
```

### 7.7 Trino-created view smoke test

실제 사용 방식인 Trino-created view도 추가로 검증했다.

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
CREATE SCHEMA IF NOT EXISTS hive.shared;
CREATE OR REPLACE VIEW hive.shared.trino_smoke_view AS
SELECT country, count(*) AS customer_count
FROM iceberg.ecommerce.customers
GROUP BY country;
SELECT count(*) FROM hive.shared.trino_smoke_view;
DROP VIEW hive.shared.trino_smoke_view;
"
```

결과:

```text
CREATE SCHEMA
CREATE VIEW
"9"
DROP VIEW
```

여기서 `DROP VIEW`까지는 Trino에서 정상 처리된다. 다만 `DROP SCHEMA hive.shared`를 Trino에서 바로 실행하면 다음 에러가 날 수 있다.

```text
No factory for location: file:/opt/hive/data/warehouse/shared.db
```

이는 Hive schema location이 file path로 잡힌 상태에서 Trino Hive connector가 해당 location factory를 만들지 못하기 때문이다. 현재 설계에서는 schema를 장기적으로 `hive.shared` 같은 공용 namespace로 유지하고 view만 생성/삭제하는 패턴을 권장한다. 테스트 후 schema까지 지우고 싶다면 Spark Thrift Server의 beeline으로 정리한다.

```bash
kubectl exec -n spark deploy/spark-thrift-server -- \
  /opt/spark/bin/beeline -u jdbc:hive2://localhost:10000 \
  -e "DROP DATABASE IF EXISTS shared;"
```

---

## 8. Trino에서 View를 만드는 사용법

이번 환경의 실제 사용 의도는 Trino에서 view를 만드는 것이다. 기본 패턴은 다음과 같다.

```bash
kubectl exec -n trino deploy/trino -- trino
```

Trino CLI 안에서:

```sql
CREATE SCHEMA IF NOT EXISTS hive.shared;

CREATE OR REPLACE VIEW hive.shared.customer_summary AS
SELECT
  country,
  count(*) AS customer_count
FROM iceberg.ecommerce.customers
GROUP BY country;

SELECT *
FROM hive.shared.customer_summary
ORDER BY country;
```

한 번에 실행하려면:

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
CREATE SCHEMA IF NOT EXISTS hive.shared;
CREATE OR REPLACE VIEW hive.shared.customer_summary AS
SELECT country, count(*) AS customer_count
FROM iceberg.ecommerce.customers
GROUP BY country;
SELECT * FROM hive.shared.customer_summary ORDER BY country;
"
```

목록 확인:

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
SHOW SCHEMAS FROM hive;
SHOW TABLES FROM hive.shared;
SHOW CREATE VIEW hive.shared.customer_summary;
"
```

정리:

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
DROP VIEW IF EXISTS hive.shared.customer_summary;
"
```

주의:

- `iceberg.ecommerce.*`는 실제 Iceberg table이다.
- `hive.shared.*`는 view definition을 저장하는 영역으로 사용한다.
- Trino에서 만든 view는 Trino view 형식으로 Hive Metastore에 저장된다.
- Trino에서 `DROP VIEW`는 정상 동작한다. `DROP SCHEMA`는 file warehouse location 때문에 실패할 수 있으므로, 공용 schema는 유지하고 view만 정리하는 방식을 권장한다.
- Spark/Hive에서 Trino-created view를 읽는 것은 호환성 이슈가 있을 수 있다.
- Superset/Trino SQL Lab에서 재사용할 view라면 `hive.shared.*`에 만드는 것이 이번 설계의 주 사용 방식이다.

---

## 9. 최종 설정 스냅샷

### 9.1 Hive Metastore values

```yaml
image:
  repository: apache/hive
  tag: "4.0.0"

postgresqlClient:
  repository: docker.io/bitnami/postgresql
  tag: "latest"

database:
  host: "airflow-postgresql.airflow.svc.cluster.local"
  user: "airflow"
  password: "airflow"
  name: "metastore"
  bootstrapDatabase: "airflow"

s3:
  warehouseDir: "file:/tmp/hive/warehouse"
```

### 9.2 Trino Hive catalog

```properties
connector.name=hive
hive.metastore.uri=thrift://hive-metastore.hive-metastore.svc.cluster.local:9083
fs.native-s3.enabled=true
s3.endpoint=http://minio.minio.svc.cluster.local:9000
s3.aws-access-key=admin
s3.aws-secret-key=password
s3.path-style-access=true
s3.region=us-east-1
hive.storage-format=PARQUET
hive.hive-views.enabled=true
```

### 9.3 Spark Thrift Server Hive settings

```properties
spark.sql.catalogImplementation=hive
spark.sql.warehouse.dir=file:/tmp/hive/warehouse
spark.hadoop.hive.metastore.uris=thrift://hive-metastore.hive-metastore.svc.cluster.local:9083
```

---

## 10. 교훈

1. **ConfigMap key는 catalog가 아니다.**  
   Trino catalog는 `/etc/trino/catalog/*.properties`로 mount되어야 실제로 로딩된다.

2. **공식 이미지도 JDBC driver를 보장하지 않는다.**  
   Hive Metastore가 PostgreSQL을 쓰려면 `org.postgresql.Driver` jar가 classpath에 있어야 한다.

3. **시스템 디렉터리에 emptyDir를 mount하지 말 것.**  
   `/lib` 같은 경로를 덮으면 shell과 runtime loader가 사라져 `no such file or directory`처럼 보이는 기묘한 장애가 난다.

4. **DB dependency는 lifecycle script와 chart 양쪽에서 보장하는 것이 좋다.**  
   full start에서는 `manage-project.sh`가 보장하고, chart 단독 배포에서는 initContainer가 보장하도록 이중 안전장치를 두었다.

5. **View store와 table store를 섞지 말 것.**  
   이번 Hive Metastore는 실제 data lake table 저장소가 아니라 view metadata store다. 실제 data table은 계속 Iceberg/Nessie/MinIO가 담당한다.

6. **S3A warehouse는 서버 양쪽의 classpath를 요구한다.**  
   Spark에 `hadoop-aws`를 넣는 것만으로는 충분하지 않았다. Hive Metastore server도 `s3a://`를 해석해야 해서 문제가 됐다. 이번 목적에는 `file:/tmp/hive/warehouse`가 더 단순하고 안정적이었다.

7. **Trino-created view와 Spark/Hive-created view는 같은 것이 아니다.**  
   같은 Hive Metastore에 저장되더라도 engine별 view encoding과 SQL dialect가 다를 수 있다. 최종 사용자가 Trino/Superset에서 쓸 view는 Trino에서 만들고 Trino에서 읽는 방식이 가장 안전하다.

---

## 11. 현재 남은 고려사항

1. Airflow PostgreSQL을 Hive Metastore DB로 공유하고 있다. 로컬 개발 환경에서는 충분하지만, 장기적으로는 Hive Metastore 전용 PostgreSQL chart를 두는 것이 더 깔끔할 수 있다.
2. PostgreSQL JDBC jar는 initContainer가 외부 URL에서 다운로드한다. 재현성과 오프라인 안정성을 높이려면 custom Hive Metastore image에 jar를 bake하는 편이 더 좋다.
3. `hive.hive-views.enabled=true`는 Hive-style view 읽기를 열어둔 설정이다. Trino-created view 중심으로만 사용할 거라면 향후 실제 호환성 테스트 후 유지 여부를 판단해도 된다.
4. `file:/tmp/hive/warehouse`는 view store 목적에는 충분하지만, Hive managed table을 본격적으로 만들 계획이 생기면 별도 storage 전략이 필요하다.
