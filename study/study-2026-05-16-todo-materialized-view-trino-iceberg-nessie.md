# TODO: Trino + Iceberg + Nessie 환경에서 물리적 뷰(Materialized View) 검증

## 1. 목적

이 문서는 현재 로컬 ETL/Lakehouse 플랫폼에서 다음 내용을 검증하기 위한 TODO 연구 노트다.

- 영속적 뷰(persistent view), 물리적 뷰(materialized view), CTAS 테이블의 차이를 정리한다.
- 현재 구성에서 물리적 뷰를 어디에 두어야 하는지 판단한다.
- Trino Iceberg materialized view가 Nessie REST catalog 환경에서 실제로 생성/refresh/조회되는지 테스트한다.
- Spark가 Trino materialized view를 어떻게 인지하는지 확인한다.
- 물리적 뷰가 증분 refresh를 수행할 수 있는지, 아니면 full refresh로 동작하는지 관찰한다.

이 문서는 아직 결론 문서가 아니다. 실제 클러스터에서 smoke test와 로그/메타데이터 확인을 거친 뒤 업데이트해야 한다.

---

## 2. 현재 시스템 구조 요약

현재 프로젝트의 주요 catalog 구조는 다음과 같다.

```text
Trino
  catalog: iceberg
    connector: iceberg
    catalog backend: Nessie REST catalog, main ref
    storage: MinIO

  catalog: iceberg_dev
    connector: iceberg
    catalog backend: Nessie REST catalog, dev ref
    storage: MinIO

  catalog: hive
    connector: hive
    metastore: Hive Metastore
    intended purpose: reusable Trino SQL views

Spark Thrift Server
  Iceberg/Nessie catalog access
  Hive Metastore access
```

현재 역할 분리는 다음을 기본 전제로 한다.

| 영역 | 용도 |
| :--- | :--- |
| `iceberg.ecommerce.*` | 원본/샘플 Iceberg Lakehouse 테이블 |
| `iceberg_dev.*` | Nessie dev ref 기반 실험 catalog |
| `hive.shared.*` | Trino에서 재사용 가능한 영속 logical view 저장소 |
| `iceberg.mart.*` | 물리화된 mart table 또는 materialized view 후보 영역 |

---

## 3. 뷰/테이블 개념 정리

### 3.1 영속적 뷰(Persistent View)

영속적 뷰는 실제 데이터를 저장하지 않고, 이름이 붙은 SQL 정의만 metastore/catalog에 저장하는 구조다.

예:

```sql
CREATE OR REPLACE VIEW hive.shared.country_sales_view AS
SELECT
  c.country,
  count(*) AS order_count,
  sum(o.amount) AS total_sales
FROM iceberg.ecommerce.orders o
JOIN iceberg.ecommerce.customers c
  ON o.customer_id = c.customer_id
GROUP BY c.country;
```

동작 방식:

- 저장되는 것은 SQL 정의다.
- 결과 데이터는 따로 저장하지 않는다.
- 조회할 때마다 원본 테이블을 대상으로 SQL 전체가 다시 실행된다.
- 함수처럼 호출 시점에 로직이 평가된다고 이해할 수 있다.
- 원본 데이터가 바뀌면 다음 조회 결과에 자연스럽게 반영된다.
- 대신 조인/집계가 무거우면 조회할 때마다 비용이 반복된다.

현재 시스템에서의 위치:

- `hive.shared.*`가 이 용도에 적합하다.
- Hive Metastore는 여기서 "view definition store" 역할을 한다.
- 이 뷰는 Trino/Superset 재사용성에 초점을 둔다.

주의:

- Trino가 만든 SQL view를 Spark가 완전히 같은 의미로 이해한다는 보장은 없다.
- Spark까지 공통으로 읽어야 하는 물리 데이터셋은 view보다 Iceberg table로 잡는 편이 안전하다.

### 3.2 물리적 뷰(Materialized View)

물리적 뷰는 SQL 정의뿐 아니라, 그 SQL을 실행한 결과 데이터도 물리적으로 저장하는 구조다.

개념 예:

```sql
CREATE MATERIALIZED VIEW iceberg.mart.country_sales_mv
WITH (
  format = 'PARQUET'
) AS
SELECT
  c.country,
  count(*) AS order_count,
  sum(o.amount) AS total_sales
FROM iceberg.ecommerce.orders o
JOIN iceberg.ecommerce.customers c
  ON o.customer_id = c.customer_id
GROUP BY c.country;
```

동작 방식:

- SQL 정의가 저장된다.
- SQL 결과 데이터도 저장된다.
- 조회 시 원본 테이블을 매번 다시 계산하지 않고 저장된 결과를 읽는다.
- refresh 시점에 결과 데이터를 다시 계산하거나 갱신한다.
- 엔진/커넥터가 지원하면 원본 snapshot, stale 상태, refresh, 증분 refresh 같은 의미론을 관리할 수 있다.

현재 시스템에서의 위치:

- `hive.shared.*`가 아니라 `iceberg.mart.*` 쪽이 후보 위치다.
- Trino Iceberg connector의 materialized view 기능을 사용하는 구조가 된다.
- 결과 데이터는 Iceberg storage table 형태로 MinIO에 저장되는 모델로 이해한다.
- catalog object/metadata는 Nessie REST catalog ref 위에서 관리될 가능성이 높다.

중요한 제한:

- 이 물리적 뷰의 "뷰 의미론"은 Trino가 관리한다.
- Spark는 Trino materialized view를 materialized view로 인지하지 못한다고 보는 것이 안전하다.
- Spark가 읽을 수 있는 것은 결과 storage table 또는 catalog에 노출된 물리 데이터일 수 있으나, 그것에 직접 의존하면 Trino MV 관리 의미론을 깨뜨릴 수 있다.

### 3.3 CTAS 테이블(Create Table As Select)

CTAS는 특정 시점의 쿼리 결과를 일반 테이블로 생성하는 방식이다.

예:

```sql
CREATE TABLE iceberg.mart.country_sales AS
SELECT
  c.country,
  count(*) AS order_count,
  sum(o.amount) AS total_sales
FROM iceberg.ecommerce.orders o
JOIN iceberg.ecommerce.customers c
  ON o.customer_id = c.customer_id
GROUP BY c.country;
```

또는 운영상 재생성:

```sql
CREATE OR REPLACE TABLE iceberg.mart.country_sales AS
SELECT
  c.country,
  count(*) AS order_count,
  sum(o.amount) AS total_sales
FROM iceberg.ecommerce.orders o
JOIN iceberg.ecommerce.customers c
  ON o.customer_id = c.customer_id
GROUP BY c.country;
```

동작 방식:

- 결과 데이터가 일반 Iceberg table로 저장된다.
- 시스템은 이 객체를 "뷰"가 아니라 독립적인 table로 본다.
- 원본 SQL 정의, 원본 테이블과의 dependency, stale 여부, refresh 의미론을 시스템이 자동 관리하지 않는다.
- Airflow, Spark, dbt, Trino job 등 외부 orchestration이 refresh와 lineage를 관리해야 한다.

현재 시스템에서의 위치:

- Spark와 Trino가 모두 안정적으로 공유해야 하는 물리 mart dataset은 CTAS/배치 Iceberg table이 가장 명확하다.
- `iceberg.mart.*`에 두는 것이 자연스럽다.

---

## 4. 같은 예제로 비교

목표: 국가별 주문 매출 요약을 만들고 재사용한다.

원본:

```text
iceberg.ecommerce.orders
iceberg.ecommerce.customers
```

### 4.1 영속적 뷰

```sql
CREATE OR REPLACE VIEW hive.shared.country_sales_view AS
SELECT
  c.country,
  count(*) AS order_count,
  sum(o.amount) AS total_sales
FROM iceberg.ecommerce.orders o
JOIN iceberg.ecommerce.customers c
  ON o.customer_id = c.customer_id
GROUP BY c.country;
```

조회:

```sql
SELECT *
FROM hive.shared.country_sales_view
ORDER BY total_sales DESC;
```

특징:

- SQL 정의만 저장된다.
- 조회할 때마다 원본을 다시 읽는다.
- 항상 최신 원본 데이터에 가깝게 보인다.
- 대시보드 쿼리가 무거우면 매번 비용이 발생한다.

### 4.2 Trino Iceberg Materialized View

```sql
CREATE MATERIALIZED VIEW iceberg.mart.country_sales_mv
WITH (
  format = 'PARQUET'
) AS
SELECT
  c.country,
  count(*) AS order_count,
  sum(o.amount) AS total_sales
FROM iceberg.ecommerce.orders o
JOIN iceberg.ecommerce.customers c
  ON o.customer_id = c.customer_id
GROUP BY c.country;
```

필요 시 refresh:

```sql
REFRESH MATERIALIZED VIEW iceberg.mart.country_sales_mv;
```

조회:

```sql
SELECT *
FROM iceberg.mart.country_sales_mv
ORDER BY total_sales DESC;
```

특징:

- SQL 정의와 결과 데이터가 모두 관리된다.
- 조회는 저장된 결과를 읽는다.
- 원본 데이터 변경 후 자동 반영되지 않는다.
- Airflow 등으로 refresh를 호출해야 한다.
- Trino가 지원하는 범위 안에서 stale/refresh/증분 refresh 의미론을 기대할 수 있다.

### 4.3 CTAS Mart Table

```sql
CREATE OR REPLACE TABLE iceberg.mart.country_sales AS
SELECT
  c.country,
  count(*) AS order_count,
  sum(o.amount) AS total_sales
FROM iceberg.ecommerce.orders o
JOIN iceberg.ecommerce.customers c
  ON o.customer_id = c.customer_id
GROUP BY c.country;
```

조회:

```sql
SELECT *
FROM iceberg.mart.country_sales
ORDER BY total_sales DESC;
```

특징:

- 결과 데이터가 일반 Iceberg table로 저장된다.
- Spark와 Trino가 모두 읽기 쉬운 공통 물리 dataset이다.
- 물리적 뷰처럼 보일 수 있지만, 시스템이 "view"로 관리하지 않는다.
- refresh는 `CREATE OR REPLACE TABLE`, `INSERT OVERWRITE`, `MERGE` 등으로 직접 설계해야 한다.

---

## 5. 현재 시스템 기준 기능/제약 상세표

| 항목 | 영속적 뷰: `hive.shared.*` | Trino MV: `iceberg.mart.*` | CTAS table: `iceberg.mart.*` |
| :--- | :--- | :--- | :--- |
| 저장되는 것 | SQL 정의 | SQL 정의 + 결과 데이터 | 결과 데이터 |
| 물리 데이터 저장 | 없음 | 있음 | 있음 |
| 결과 저장 위치 | 없음 | MinIO의 Iceberg storage table | MinIO의 Iceberg table |
| catalog/metadata | Hive Metastore | Nessie REST catalog + Iceberg metadata + Trino MV metadata | Nessie REST catalog + Iceberg metadata |
| 조회 시 동작 | 원본 쿼리 재실행 | 저장된 결과 조회 | 저장된 table 조회 |
| 최신성 | 조회 시 원본 기준 | 마지막 refresh 기준 | 마지막 table 재생성/갱신 기준 |
| 자동 refresh | 해당 없음 | 없음 | 없음 |
| 수동 refresh | 해당 없음 | `REFRESH MATERIALIZED VIEW` | `CREATE OR REPLACE`, `INSERT OVERWRITE`, `MERGE` 등 |
| 증분 refresh | 해당 없음 | 조건부 가능성 있음 | 직접 구현해야 함 |
| full refresh | 조회마다 사실상 full 계산 | 가능 | 가능 |
| stale 상태 | 해당 없음 | Trino가 일부 판단 가능 | 직접 관리 |
| 원본 dependency | view SQL에 존재 | Trino MV metadata에 존재 | 외부 job/dbt/Airflow에서 관리 |
| Spark 공유 | 제한적/불확실 | MV 의미론 공유 불가 | 공유 가능성이 가장 높음 |
| Trino/Superset 재사용 | 좋음 | 좋음 | 좋음 |
| 운영 복잡도 | 낮음 | 중간 | 중간~높음 |
| 대시보드 성능 개선 | 제한적 | 좋음 | 좋음 |
| semantic layer 용도 | 좋음 | 가능하지만 주 목적은 가속/물리화 | 보통 mart dataset |
| 권장 용도 | 공통 SQL 재사용 | Trino 중심 BI 가속 | Spark/Trino 공용 mart |

---

## 6. Nessie와의 관계

현재 `iceberg` catalog는 Nessie REST catalog를 사용한다. 따라서 `iceberg.mart.*`에 생성하는 table 또는 materialized view는 Nessie가 관리하는 catalog namespace/ref와 관련된다.

구조:

```text
Trino
  -> iceberg catalog
    -> Nessie REST catalog
      -> namespace/table/MV 관련 metadata
    -> MinIO
      -> Iceberg metadata files
      -> Parquet/ORC/Avro data files
```

Nessie가 관여하는 부분:

| 부분 | Nessie 관여 |
| :--- | :--- |
| namespace/table object 등록 | 관여 |
| `main`/`dev` ref별 catalog 상태 | 관여 |
| Iceberg metadata location 추적 | 관여 |
| commit/ref 이력 | 관여 |
| 실제 SQL 계산 | 관여 안 함 |
| aggregation/join 실행 | 관여 안 함 |
| 증분 refresh 판단 | 주로 Trino + Iceberg metadata |
| 실제 data file 저장 | MinIO 담당 |

중요한 ref 의미:

- `iceberg` catalog는 Nessie `main` ref를 본다.
- `iceberg_dev` catalog는 Nessie `dev` ref를 본다.
- `iceberg.mart.country_sales_mv`는 main ref 위에 생성되는 객체로 보는 것이 자연스럽다.
- `iceberg_dev.mart.country_sales_mv`는 dev ref 위의 실험 객체가 될 수 있다.

TODO:

- MV 생성 시 Nessie commit 이력이 남는지 확인한다.
- MV refresh 시 Nessie commit 이력이 남는지 확인한다.
- `main`과 `dev`에서 같은 이름의 MV를 각각 만들 수 있는지 확인한다.
- branch merge/rebase 시 MV metadata가 어떻게 보이는지 확인한다.

---

## 7. Spark와의 공유성

중요 결론:

> Trino Iceberg materialized view의 "materialized view 의미론"은 Trino 단위로 관리된다. Spark는 그것을 Trino materialized view로 인지하지 못한다고 보는 것이 안전하다.

Spark가 이해할 수 있는 것:

- 일반 Iceberg table
- Iceberg metadata를 통해 노출되는 table-like object
- Hive Metastore에 등록된 일부 Hive-compatible metadata

Spark가 이해하지 못한다고 봐야 하는 것:

- Trino MV의 refresh 정의
- Trino MV의 stale 상태
- Trino MV의 증분 refresh 판단
- Trino MV의 internal storage table 관리 규칙

따라서:

| 목적 | 권장 구조 |
| :--- | :--- |
| Trino/Superset만 쓰는 BI cache | Trino Iceberg materialized view |
| Spark와 Trino가 모두 안정적으로 읽는 mart | CTAS/배치 Iceberg table |
| 공통 SQL 이름 재사용 | Hive Metastore-backed Trino persistent view |

주의:

- Trino MV의 내부 storage table이 Spark에서 보이더라도 직접 읽거나 쓰는 것을 운영 전제로 삼으면 위험하다.
- 내부 storage table을 Spark가 수정하면 Trino MV의 metadata/stale/refresh 의미론이 깨질 수 있다.
- Spark까지 공유해야 한다면 처음부터 `iceberg.mart.*` 일반 table로 설계한다.

---

## 8. 증분 refresh에 대한 현재 가정

Trino Iceberg connector의 materialized view는 refresh 시 다음 방식 중 하나로 동작할 수 있다.

- 가능한 경우 incremental refresh
- 조건이 맞지 않으면 full refresh

이것은 "항상 증분처리"가 아니다.

증분 refresh가 기대되는 경우:

- 원본이 Iceberg table이다.
- 원본이 append-only에 가깝다.
- 쿼리가 비교적 단순하다.
- 원본 snapshot history가 남아 있다.
- delete/update/merge로 인한 복잡한 row-level 변경이 적다.

full refresh로 떨어질 가능성이 큰 경우:

- 원본 table snapshot history가 만료되었다.
- 원본에 delete/update/merge가 많다.
- join/aggregation이 복잡하다.
- 쿼리 형태가 incremental refresh 조건을 만족하지 못한다.
- source table이 Iceberg 외부 catalog/table을 섞는다.

현재 프로젝트에서 검증할 필요가 있는 대표 케이스:

1. 단일 Iceberg table projection/filter MV
2. 단일 Iceberg table group by MV
3. 두 Iceberg table join + group by MV
4. append 후 refresh
5. update/delete/merge 후 refresh
6. snapshot expiration 후 refresh

---

## 9. 검증 TODO

### 9.1 사전 확인

```bash
kubectl get pods -n trino
kubectl get pods -n nessie
kubectl get pods -n minio
kubectl get pods -n spark
```

```bash
kubectl exec -n trino deploy/trino -- trino --execute "SHOW CATALOGS"
```

기대:

```text
hive
iceberg
iceberg_dev
```

### 9.2 Iceberg mart schema 생성

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
CREATE SCHEMA IF NOT EXISTS iceberg.mart
WITH (location = 's3://iceberg-data/mart/');
SHOW SCHEMAS FROM iceberg;
"
```

확인:

- `iceberg.mart` schema가 생성되는지
- Nessie commit 이력에 namespace 생성이 남는지
- MinIO에 mart path가 생기는지

### 9.3 가장 단순한 MV 생성 테스트

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
CREATE MATERIALIZED VIEW iceberg.mart.mv_customers_by_country
WITH (
  format = 'PARQUET'
) AS
SELECT
  country,
  count(*) AS customer_count
FROM iceberg.ecommerce.customers
GROUP BY country;
"
```

확인:

- 문법이 통과하는지
- Nessie REST catalog 조합에서 materialized view creation이 지원되는지
- 생성 직후 조회가 가능한지
- 생성 직후 데이터가 비어 있으면 refresh가 필요한지

조회:

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
SELECT *
FROM iceberg.mart.mv_customers_by_country
ORDER BY country;
"
```

### 9.4 Refresh 테스트

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
REFRESH MATERIALIZED VIEW iceberg.mart.mv_customers_by_country;
SELECT *
FROM iceberg.mart.mv_customers_by_country
ORDER BY country;
"
```

확인:

- refresh 성공 여부
- refresh 시간
- Trino logs에 incremental/full refresh 관련 메시지가 있는지
- MinIO 파일이 새로 생기는지
- Nessie commit 이력이 생기는지

### 9.5 원본 append 후 refresh

테스트용으로 원본 table에 row를 추가한다. 실제 샘플 데이터 보존 정책에 따라 테스트 전후 cleanup 전략을 정해야 한다.

예시:

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
INSERT INTO iceberg.ecommerce.customers
SELECT 9999, 'Test Customer', 'KR';
"
```

그 다음:

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
SELECT *
FROM iceberg.mart.mv_customers_by_country
WHERE country = 'KR';

REFRESH MATERIALIZED VIEW iceberg.mart.mv_customers_by_country;

SELECT *
FROM iceberg.mart.mv_customers_by_country
WHERE country = 'KR';
"
```

확인:

- refresh 전에는 old result가 보이는지
- refresh 후에는 KR count가 증가하는지
- refresh가 incremental로 동작했는지 full refresh로 동작했는지 로그/메타데이터로 추정한다.

주의:

- 테스트 row cleanup이 필요하다.
- 원본 샘플 테이블을 오염시키지 않으려면 별도 test schema/table을 만드는 편이 낫다.

### 9.6 Spark 인지 여부 테스트

Spark Thrift Server 또는 Spark SQL에서 다음을 확인한다.

```sql
SHOW TABLES IN iceberg.mart;
SELECT * FROM iceberg.mart.mv_customers_by_country;
```

확인:

- Spark가 MV 이름을 table처럼 볼 수 있는지
- 조회가 되는지
- Spark가 materialized view metadata를 이해하는지
- Spark가 조회하지 못한다면 어떤 에러가 나는지

예상:

- Spark가 Trino materialized view 의미론을 이해하지 못할 가능성이 높다.
- 조회가 되더라도 일반 table/storage object처럼 보일 가능성이 크다.
- 운영 설계에서 Spark 공용 dataset으로 Trino MV를 쓰는 것은 피하는 편이 안전하다.

### 9.7 CTAS와 비교 테스트

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
CREATE OR REPLACE TABLE iceberg.mart.tbl_customers_by_country AS
SELECT
  country,
  count(*) AS customer_count
FROM iceberg.ecommerce.customers
GROUP BY country;
"
```

비교:

```bash
kubectl exec -n trino deploy/trino -- trino --execute "
SELECT 'mv' AS kind, count(*) FROM iceberg.mart.mv_customers_by_country
UNION ALL
SELECT 'table' AS kind, count(*) FROM iceberg.mart.tbl_customers_by_country;
"
```

확인:

- Trino에서 둘 다 조회 가능한지
- Spark에서 CTAS table은 안정적으로 조회 가능한지
- Nessie/MinIO metadata가 어떻게 다르게 생기는지
- refresh/replace 작업 시 commit 이력이 어떻게 다른지

---

## 10. 운영 판단 기준

### 10.1 Trino Materialized View를 채택해도 좋은 경우

- 사용자가 대부분 Trino/Superset 경유로 조회한다.
- Spark에서 해당 객체를 직접 다룰 필요가 없다.
- refresh를 Airflow에서 `REFRESH MATERIALIZED VIEW`로 관리할 수 있다.
- MV 생성/refresh가 Nessie REST catalog 조합에서 안정적으로 동작한다.
- 증분 refresh가 실제 쿼리 패턴에서 유의미하게 동작한다.

### 10.2 CTAS Iceberg Mart Table이 더 좋은 경우

- Spark와 Trino가 모두 같은 결과 dataset을 안정적으로 읽어야 한다.
- MV의 증분 refresh가 기대만큼 동작하지 않는다.
- lineage와 refresh를 Airflow/dbt/Spark job에서 명시적으로 관리하는 것이 더 낫다.
- table overwrite/merge 전략을 직접 제어하고 싶다.
- "뷰" 의미론보다 "공통 mart dataset"이 중요하다.

### 10.3 Persistent View가 더 좋은 경우

- 물리화가 필요하지 않다.
- 항상 최신 원본 기준 결과가 중요하다.
- 쿼리가 가볍거나 호출 빈도가 낮다.
- Superset/Trino에서 복잡한 SQL을 이름 붙여 재사용하려는 목적이다.

---

## 11. 임시 결론

현재 시스템에서 물리적 뷰는 구현 가능성이 있다. 단, 다음 전제가 붙는다.

1. 물리적 뷰는 `hive.shared.*`가 아니라 `iceberg.mart.*`에 둔다.
2. 구현 주체는 Trino Iceberg connector다.
3. catalog/versioning layer로 Nessie가 관여한다.
4. 실제 데이터와 Iceberg metadata는 MinIO에 저장된다.
5. refresh 계산과 MV 의미론은 Trino가 관리한다.
6. Spark는 Trino MV를 materialized view로 인지하지 못한다고 보는 것이 안전하다.
7. Spark/Trino 공용 물리 dataset이 필요하면 CTAS/배치 Iceberg table이 더 안전하다.
8. 증분 refresh는 가능성은 있지만 보장으로 두면 안 된다. 실제 쿼리와 snapshot 조건에서 테스트해야 한다.

최종 설계 후보:

| 목적 | 후보 |
| :--- | :--- |
| 공통 SQL 재사용 | `hive.shared.*` persistent view |
| Trino/Superset BI 가속 | `iceberg.mart.*` Trino materialized view |
| Spark/Trino 공용 mart | `iceberg.mart.*` CTAS/managed Iceberg table |
| refresh orchestration | Airflow DAG |
| dev/main 실험 분리 | Nessie `iceberg_dev` / `iceberg` catalog 분리 |

---

## 12. 참고 링크

- Trino Iceberg connector materialized views: https://trino.io/docs/current/connector/iceberg.html#materialized-views
- Trino `CREATE MATERIALIZED VIEW`: https://trino.io/docs/current/sql/create-materialized-view.html
- Trino `REFRESH MATERIALIZED VIEW`: https://trino.io/docs/current/sql/refresh-materialized-view.html
- Apache Iceberg: https://iceberg.apache.org/
- Project Nessie: https://projectnessie.org/

---

## 13. 테스트 실행 결과: 2026-05-16

### 13.1 실행 환경

전체 플랫폼을 `./manage-project.sh start`로 기동한 뒤 테스트했다.

기동 후 주요 상태:

```text
hive-metastore       1/1 Running
trino                1/1 Running
spark-thrift-server  1/1 Running
iceberg-nessie-restore SparkApplication COMPLETED
```

Trino catalog:

```text
hive
iceberg
iceberg_dev
jmx
memory
system
tpcds
tpch
```

샘플 데이터 count:

```text
iceberg.ecommerce.customers = 15
iceberg.ecommerce.products  = 14
iceberg.ecommerce.orders    = 20
```

### 13.2 `iceberg.mart` schema 생성

실행:

```sql
CREATE SCHEMA IF NOT EXISTS iceberg.mart
WITH (location = 's3://iceberg-data/mart/');
```

결과:

```text
CREATE SCHEMA
```

확인:

```sql
SHOW SCHEMAS FROM iceberg;
```

결과:

```text
ecommerce
information_schema
mart
system
```

Nessie history에도 `update namespace mart` commit이 남았다.

### 13.3 테스트 source table 생성

샘플 원본 테이블을 오염시키지 않기 위해 `iceberg.mart.mv_test_source`를 별도로 만들었다.

실행:

```sql
CREATE TABLE iceberg.mart.mv_test_source (
  country varchar,
  amount integer
)
WITH (format = 'PARQUET');

INSERT INTO iceberg.mart.mv_test_source
VALUES ('KR', 100), ('KR', 200), ('US', 50);
```

결과:

```text
CREATE TABLE
INSERT: 3 rows
```

확인:

```sql
SELECT
  country,
  count(*) AS order_count,
  sum(amount) AS total_sales
FROM iceberg.mart.mv_test_source
GROUP BY country
ORDER BY country;
```

결과:

```text
KR  2  300
US  1  50
```

Nessie history:

```text
Create ICEBERG_TABLE mart.mv_test_source
Update ICEBERG_TABLE mart.mv_test_source
```

MinIO:

```text
local/iceberg-data/mart/mv_test_source_.../data/...
local/iceberg-data/mart/mv_test_source_.../metadata/...
```

### 13.4 Trino Iceberg Materialized View 생성 테스트

실행:

```sql
CREATE MATERIALIZED VIEW iceberg.mart.mv_test_sales
WITH (
  format = 'PARQUET'
) AS
SELECT
  country,
  count(*) AS order_count,
  sum(amount) AS total_sales
FROM iceberg.mart.mv_test_source
GROUP BY country;
```

결과:

```text
Query failed: createMaterializedView is not supported for Iceberg REST catalog
```

결론:

현재 프로젝트의 `iceberg` catalog는 Nessie REST catalog 기반이다. 이 조합에서는 Trino가 Iceberg materialized view 생성을 지원하지 않는다.

따라서 다음 항목은 현재 구조에서 수행 불가다.

- `REFRESH MATERIALIZED VIEW`
- Trino MV stale 상태 확인
- Trino MV 증분 refresh 확인
- Trino MV storage table 확인
- Spark에서 Trino MV 인지 여부 확인

중요한 수정 결론:

> 현재 구조에서 "Trino Iceberg materialized view"는 구현 가능성이 있는 후보가 아니라, 실제 테스트 기준으로는 `Iceberg REST catalog` 제약 때문에 불가능하다.

### 13.5 CTAS Iceberg Mart Table 테스트

Trino materialized view가 실패했으므로, 같은 집계를 CTAS table로 생성했다.

실행:

```sql
CREATE TABLE iceberg.mart.ctas_test_sales
WITH (format = 'PARQUET') AS
SELECT
  country,
  count(*) AS order_count,
  sum(amount) AS total_sales
FROM iceberg.mart.mv_test_source
GROUP BY country;
```

결과:

```text
CREATE TABLE: 2 rows
```

Trino 조회:

```sql
SELECT *
FROM iceberg.mart.ctas_test_sales
ORDER BY country;
```

결과:

```text
KR  2  300
US  1  50
```

Nessie history:

```text
Create ICEBERG_TABLE mart.ctas_test_sales
```

MinIO:

```text
local/iceberg-data/mart/ctas_test_sales_.../data/...
local/iceberg-data/mart/ctas_test_sales_.../metadata/...
```

### 13.6 Spark Thrift Server 공유성 테스트

Spark Thrift Server에서 `iceberg.mart` namespace와 CTAS table이 보이는지 확인했다.

실행:

```sql
SHOW NAMESPACES IN iceberg;
```

결과:

```text
mart
ecommerce
```

실행:

```sql
SHOW TABLES IN iceberg.mart;
```

결과:

```text
mart  ctas_test_sales  false
mart  mv_test_source   false
```

Spark Thrift Server에서 CTAS 결과 조회:

```sql
SELECT *
FROM iceberg.mart.ctas_test_sales
ORDER BY country;
```

결과:

```text
KR  2  300
US  1  50
```

결론:

> CTAS로 만든 `iceberg.mart.*` Iceberg table은 Trino와 Spark Thrift Server 양쪽에서 정상 공유된다.

### 13.7 CTAS stale/recreate 동작 테스트

source table에 데이터를 추가했다.

실행:

```sql
INSERT INTO iceberg.mart.mv_test_source
VALUES ('KR', 400);
```

source table 재집계:

```text
KR  3  700
US  1  50
```

하지만 기존 CTAS table 조회 결과:

```text
KR  2  300
US  1  50
```

즉, CTAS table은 원본 변경을 자동 반영하지 않는다. 이 table은 마지막 생성/갱신 시점의 물리 dataset이다.

그 다음 `CREATE OR REPLACE TABLE AS`로 재생성했다.

실행:

```sql
CREATE OR REPLACE TABLE iceberg.mart.ctas_test_sales
WITH (format = 'PARQUET') AS
SELECT
  country,
  count(*) AS order_count,
  sum(amount) AS total_sales
FROM iceberg.mart.mv_test_source
GROUP BY country;
```

결과:

```text
CREATE TABLE: 2 rows
```

Trino 조회:

```text
KR  3  700
US  1  50
```

Spark Thrift Server 조회:

```text
KR  3  700
US  1  50
```

Nessie history:

```text
Update ICEBERG_TABLE mart.mv_test_source
Update ICEBERG_TABLE mart.ctas_test_sales
```

MinIO:

- `ctas_test_sales_.../data/` 아래에 새 Parquet file이 추가되었다.
- `ctas_test_sales_.../metadata/` 아래에 새 metadata/snapshot file이 추가되었다.
- 이전 snapshot/data file도 object storage에 남아 있다.

### 13.8 최종 테스트 결론

실제 테스트 결과 기준으로 현재 구조의 결론은 다음과 같다.

| 항목 | 결과 |
| :--- | :--- |
| `iceberg.mart` schema 생성 | 가능 |
| 테스트 source Iceberg table 생성/insert | 가능 |
| Trino Iceberg materialized view 생성 | 불가 |
| 실패 이유 | `createMaterializedView is not supported for Iceberg REST catalog` |
| `REFRESH MATERIALIZED VIEW` | MV 생성 불가로 테스트 불가 |
| 증분 refresh | MV 생성 불가로 테스트 불가 |
| CTAS Iceberg mart table 생성 | 가능 |
| CTAS table Trino 조회 | 가능 |
| CTAS table Spark Thrift Server 조회 | 가능 |
| CTAS source 변경 자동 반영 | 안 됨 |
| `CREATE OR REPLACE TABLE AS`로 CTAS 갱신 | 가능 |
| Nessie commit 추적 | 가능 |
| MinIO physical files 확인 | 가능 |

따라서 현재 시스템의 실질적인 설계 결론은 다음과 같이 수정해야 한다.

| 목적 | 현재 구조에서의 현실적 선택 |
| :--- | :--- |
| 공통 SQL 재사용 | `hive.shared.*` persistent view |
| Trino/Superset view layer | `hive.shared.*` persistent view |
| Spark/Trino 공용 물리 mart | `iceberg.mart.*` CTAS/managed Iceberg table |
| materialized view refresh 의미론 | 현재 Nessie REST catalog 기반 `iceberg`에서는 사용 불가 |
| 물리 mart refresh orchestration | Airflow DAG 또는 Spark/Trino job |

최종적으로:

> 현재 프로젝트에서 "물리적 뷰"에 해당하는 운영 패턴은 Trino materialized view가 아니라 `iceberg.mart.*` CTAS/managed Iceberg table + Airflow refresh orchestration으로 잡는 것이 맞다.

---

## 14. 추가 테스트: Hive Metastore-backed Iceberg catalog로 MV 구성

### 14.1 테스트 목적

13장에서 확인한 실패 원인은 `Nessie REST catalog`였다.

```text
createMaterializedView is not supported for Iceberg REST catalog
```

따라서 기존 Hive Metastore를 계속 활용하면서, Trino에 별도 HMS-backed Iceberg catalog를 추가하면 materialized view가 가능한지 검증했다.

목표 구조:

```text
iceberg      -> Nessie REST catalog, main
iceberg_dev  -> Nessie REST catalog, dev
hive         -> Hive connector + Hive Metastore, persistent view store
iceberg_hms  -> Iceberg connector + Hive Metastore, materialized view test
```

### 14.2 Trino catalog 추가

Trino chart에 `iceberg_hms` catalog를 추가했다.

```properties
connector.name=iceberg
iceberg.catalog.type=hive_metastore
hive.metastore.uri=thrift://hive-metastore.hive-metastore.svc.cluster.local:9083
fs.native-s3.enabled=true
s3.endpoint=http://minio.minio.svc.cluster.local:9000
s3.path-style-access=true
s3.aws-access-key=admin
s3.aws-secret-key=password
s3.region=us-east-1
```

Trino rollout 후 확인:

```sql
SHOW CATALOGS;
```

결과:

```text
hive
iceberg
iceberg_dev
iceberg_hms
jmx
memory
system
tpcds
tpch
```

### 14.3 Hive Metastore S3A 보강

처음 `iceberg_hms.mart` schema 생성은 실패했다.

```sql
CREATE SCHEMA IF NOT EXISTS iceberg_hms.mart
WITH (location = 's3a://iceberg-data/hms-mart/');
```

초기 실패:

```text
Class org.apache.hadoop.fs.s3a.S3AFileSystem not found
```

조치:

- Hive Metastore pod에 `hadoop-aws-3.3.6.jar`를 `/opt/hive/lib/hadoop-aws.jar`로 mount
- `aws-java-sdk-bundle-1.12.367.jar`를 `/opt/hive/lib/aws-java-sdk-bundle.jar`로 mount
- `HADOOP_CLASSPATH=/opt/hive/lib/*` 추가

이후 S3A class 문제는 해결되었지만, 다음 실패가 남았다.

```text
Failed to create external path s3a://iceberg-data/hms-mart for database mart.
This may result in access not being allowed if the StorageBasedAuthorizationProvider is enabled: null
```

컨테이너 내부에서 다음 명령은 성공했다.

```bash
HADOOP_CLASSPATH="/opt/hive/lib/*" /opt/hadoop/bin/hadoop fs \
  -Dfs.s3a.endpoint=http://minio.minio.svc.cluster.local:9000 \
  -Dfs.s3a.access.key=admin \
  -Dfs.s3a.secret.key=password \
  -Dfs.s3a.path.style.access=true \
  -Dfs.s3a.connection.ssl.enabled=false \
  -ls s3a://iceberg-data/
```

따라서 HMS 프로세스가 읽는 Hadoop/Hive config에 S3A 설정을 명시적으로 주입했다.

추가 조치:

- `hive-metastore-config` ConfigMap 추가
- `/opt/hive/conf/hive-site.xml` mount
- `/opt/hadoop/etc/hadoop/core-site.xml` mount
- `hive.metastore.warehouse.dir=s3a://iceberg-data/hive-warehouse`
- `fs.s3a.endpoint`, access key, secret key, path-style, SSL disabled 설정 추가

이후 schema 생성 성공:

```text
CREATE SCHEMA
```

### 14.4 HMS-backed Iceberg source table 생성

실행:

```sql
CREATE TABLE iceberg_hms.mart.mv_hms_test_source (
  country varchar,
  amount integer
)
WITH (format = 'PARQUET');

INSERT INTO iceberg_hms.mart.mv_hms_test_source
VALUES ('KR', 100), ('KR', 200), ('US', 50);
```

결과:

```text
CREATE TABLE
INSERT: 3 rows
```

### 14.5 HMS-backed Trino materialized view 생성

실행:

```sql
CREATE MATERIALIZED VIEW iceberg_hms.mart.mv_hms_test_sales
WITH (format = 'PARQUET') AS
SELECT
  country,
  count(*) AS order_count,
  sum(amount) AS total_sales
FROM iceberg_hms.mart.mv_hms_test_source
GROUP BY country;
```

결과:

```text
CREATE MATERIALIZED VIEW
```

조회:

```sql
SELECT *
FROM iceberg_hms.mart.mv_hms_test_sales
ORDER BY country;
```

결과:

```text
KR  2  300
US  1  50
```

`SHOW CREATE MATERIALIZED VIEW` 결과 핵심:

```sql
CREATE MATERIALIZED VIEW iceberg_hms.mart.mv_hms_test_sales
WHEN STALE INLINE
WITH (
   format = 'PARQUET',
   format_version = 2,
   location = 's3a://iceberg-data/hms-mart/mv_hms_test_sales-...',
   storage_schema = 'mart'
) AS
SELECT
  country,
  count(*) order_count,
  sum(amount) total_sales
FROM iceberg_hms.mart.mv_hms_test_source
GROUP BY country
```

생성 직후 MinIO에는 MV location 아래 metadata만 있었다.

```text
mv_hms_test_sales-.../metadata/00000-....metadata.json
```

### 14.6 Refresh 테스트

실행:

```sql
REFRESH MATERIALIZED VIEW iceberg_hms.mart.mv_hms_test_sales;
```

결과:

```text
REFRESH MATERIALIZED VIEW: 2 rows
```

Refresh 후 MinIO에는 MV data file과 snapshot metadata가 생성되었다.

```text
mv_hms_test_sales-.../data/20260516_130503_....parquet
mv_hms_test_sales-.../metadata/00001-....metadata.json
mv_hms_test_sales-.../metadata/snap-....avro
```

따라서 HMS-backed Iceberg catalog에서는 Trino materialized view가 실제 물리 data file을 생성한다.

### 14.7 원본 변경 후 stale/refresh 동작

원본에 row를 추가했다.

```sql
INSERT INTO iceberg_hms.mart.mv_hms_test_source
VALUES ('KR', 400);
```

source 재집계:

```text
KR  3  700
US  1  50
```

이 시점의 MV 조회는 KR 3/700을 반환했다. 생성 직후 아직 refresh된 물리 결과가 없던 상태라 `WHEN STALE INLINE`이 원본 쿼리를 inline 실행한 것으로 해석된다.

그 다음 refresh를 수행했다.

```sql
REFRESH MATERIALIZED VIEW iceberg_hms.mart.mv_hms_test_sales;
```

결과:

```text
KR  3  700
US  1  50
```

이후 원본에 다시 row를 추가했다.

```sql
INSERT INTO iceberg_hms.mart.mv_hms_test_source
VALUES ('US', 25);
```

source 재집계:

```text
KR  3  700
US  2  75
```

하지만 MV 조회 결과:

```text
KR  3  700
US  1  50
```

즉 refresh 이후에는 저장된 물리 결과를 읽고, 원본 변경을 자동 반영하지 않았다.

다시 refresh:

```sql
REFRESH MATERIALIZED VIEW iceberg_hms.mart.mv_hms_test_sales;
```

결과:

```text
REFRESH MATERIALIZED VIEW: 2 rows
KR  3  700
US  2  75
```

결론:

- HMS-backed Trino MV는 명시적 refresh 후 물리 결과를 저장한다.
- 원본 변경은 자동 반영되지 않는다.
- 최신 물리 결과를 원하면 `REFRESH MATERIALIZED VIEW`가 필요하다.
- 이번 테스트에서는 증분 refresh 여부까지는 판정하지 않았다. 작은 데이터셋이라 full/incremental 구분이 어렵다.

### 14.8 Spark Thrift Server 인지 여부

Spark Thrift Server에서 HMS namespace는 보였다.

```sql
SHOW DATABASES;
```

결과:

```text
default
mart
```

Spark에서 HMS table 목록도 보였다.

```sql
SHOW TABLES IN mart;
```

결과:

```text
mart  mv_hms_test_source  false
mart  mv_hms_test_sales   false
```

하지만 Spark 조회는 실패했다.

source table 조회:

```sql
SELECT *
FROM mart.mv_hms_test_source
ORDER BY country, amount;
```

결과:

```text
java.lang.RuntimeException: java.lang.InstantiationException
```

해석:

- Spark가 HMS metadata에서 table을 발견한다.
- 하지만 현재 Spark Thrift Server는 HMS-backed Iceberg catalog로 이 table을 읽도록 설정되어 있지 않다.
- 그래서 Iceberg table이 아니라 일반 Hive table처럼 해석하다 실패한 것으로 보인다.

MV 조회:

```sql
SELECT *
FROM mart.mv_hms_test_sales
ORDER BY country;
```

결과:

```text
[PARSE_SYNTAX_ERROR] Syntax error at or near end of input.
SQL of VIEW spark_catalog.mart.mv_hms_test_sales ...
```

해석:

- Spark가 Trino materialized view를 Spark-compatible materialized view로 이해하지 못한다.
- Trino MV metadata/view SQL을 Spark parser가 처리하지 못한다.
- Spark에서 Trino MV를 공용 query object로 쓰면 안 된다.

### 14.9 추가 테스트 결론

| 항목 | 결과 |
| :--- | :--- |
| 기존 HMS를 활용한 별도 `iceberg_hms` catalog 추가 | 가능 |
| HMS-backed Iceberg schema on MinIO | 가능, 단 HMS S3A 설정 보강 필요 |
| HMS-backed Iceberg source table 생성/insert | 가능 |
| HMS-backed Trino materialized view 생성 | 가능 |
| `REFRESH MATERIALIZED VIEW` | 가능 |
| MV physical data file 생성 | 가능 |
| 원본 변경 자동 반영 | 안 됨 |
| refresh 후 최신 결과 반영 | 가능 |
| Spark에서 HMS source table 목록 확인 | 가능 |
| Spark에서 HMS source table 조회 | 현재 설정으로 실패 |
| Spark에서 Trino MV 조회 | 실패 |
| Nessie branch/versioning 적용 | `iceberg_hms`에는 적용 안 됨 |

최종 수정 결론:

> 현재 Hive Metastore를 계속 써먹으면서 물리적 뷰를 구성하는 것은 가능하다. 단, Nessie REST catalog의 `iceberg`가 아니라 별도 HMS-backed Iceberg catalog인 `iceberg_hms`를 추가해야 한다.

운영 관점 정리:

| 목적 | 추천 구조 |
| :--- | :--- |
| Nessie branch 기반 Lakehouse table | `iceberg`, `iceberg_dev` |
| Trino/Superset 영속 logical view | `hive.shared.*` |
| Trino 전용 materialized view | `iceberg_hms.mart.*` |
| Spark/Trino 공용 물리 mart | `iceberg.mart.*` 또는 별도 Spark 설정이 완료된 HMS Iceberg table |

중요한 trade-off:

- `iceberg_hms` MV는 Trino에서는 잘 동작한다.
- 하지만 Nessie branch/versioning을 쓰지 않는다.
- Spark는 현재 설정 그대로는 `iceberg_hms` Iceberg table/MV를 읽지 못한다.
- Spark까지 공유해야 하면 Spark에도 HMS-backed Iceberg catalog를 별도로 설정하거나, 기존 Nessie-backed `iceberg.mart.*` CTAS table 패턴을 유지하는 편이 안전하다.
