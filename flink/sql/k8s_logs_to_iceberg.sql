SET 'execution.runtime-mode' = 'streaming';
SET 'execution.checkpointing.interval' = '60s';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'pipeline.name' = 'Kafka k8s_logs to Iceberg bronze';

CREATE CATALOG iceberg WITH (
  'type' = 'iceberg',
  'catalog-type' = 'rest',
  'uri' = 'http://nessie.nessie.svc.cluster.local:19120/iceberg/main',
  'io-impl' = 'org.apache.iceberg.aws.s3.S3FileIO',
  's3.endpoint' = 'http://minio.minio.svc.cluster.local:9000',
  's3.path-style-access' = 'true',
  's3.access-key-id' = 'admin',
  's3.secret-access-key' = 'password',
  's3.region' = 'us-east-1',
  'client.region' = 'us-east-1'
);

CREATE DATABASE IF NOT EXISTS iceberg.logs;

CREATE TABLE IF NOT EXISTS iceberg.logs.k8s_logs_bronze (
  raw_log STRING,
  kafka_topic STRING,
  kafka_partition INT,
  kafka_offset BIGINT,
  kafka_timestamp TIMESTAMP_LTZ(3),
  ingested_at TIMESTAMP_LTZ(3)
) WITH (
  'format-version' = '2',
  'write.format.default' = 'parquet'
);

CREATE TEMPORARY TABLE kafka_k8s_logs (
  raw_log STRING,
  kafka_topic STRING METADATA FROM 'topic' VIRTUAL,
  kafka_partition INT METADATA FROM 'partition' VIRTUAL,
  kafka_offset BIGINT METADATA FROM 'offset' VIRTUAL,
  kafka_timestamp TIMESTAMP_LTZ(3) METADATA FROM 'timestamp' VIRTUAL
) WITH (
  'connector' = 'kafka',
  'topic' = 'k8s_logs',
  'properties.bootstrap.servers' = 'kafka-0.kafka-headless.kafka.svc.cluster.local:9092',
  'properties.group.id' = 'flink-k8s-logs-iceberg-local',
  'scan.startup.mode' = 'latest-offset',
  'format' = 'raw'
);

INSERT INTO iceberg.logs.k8s_logs_bronze
SELECT
  raw_log,
  kafka_topic,
  kafka_partition,
  kafka_offset,
  kafka_timestamp,
  CURRENT_TIMESTAMP
FROM kafka_k8s_logs;
