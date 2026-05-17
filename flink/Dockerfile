FROM flink:1.20.3-scala_2.12-java17

ARG FLINK_KAFKA_CONNECTOR_VERSION=3.4.0-1.20
ARG ICEBERG_VERSION=1.10.1
ARG HADOOP_VERSION=3.4.1

RUN set -eux; \
    curl -fsSL "https://repo.maven.apache.org/maven2/org/apache/flink/flink-sql-connector-kafka/${FLINK_KAFKA_CONNECTOR_VERSION}/flink-sql-connector-kafka-${FLINK_KAFKA_CONNECTOR_VERSION}.jar" \
      -o /opt/flink/lib/flink-sql-connector-kafka-${FLINK_KAFKA_CONNECTOR_VERSION}.jar; \
    curl -fsSL "https://repo.maven.apache.org/maven2/org/apache/iceberg/iceberg-flink-runtime-1.20/${ICEBERG_VERSION}/iceberg-flink-runtime-1.20-${ICEBERG_VERSION}.jar" \
      -o /opt/flink/lib/iceberg-flink-runtime-1.20-${ICEBERG_VERSION}.jar; \
    curl -fsSL "https://repo.maven.apache.org/maven2/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar" \
      -o /opt/flink/lib/iceberg-aws-bundle-${ICEBERG_VERSION}.jar; \
    curl -fsSL "https://repo.maven.apache.org/maven2/org/apache/hadoop/hadoop-client-api/${HADOOP_VERSION}/hadoop-client-api-${HADOOP_VERSION}.jar" \
      -o /opt/flink/lib/hadoop-client-api-${HADOOP_VERSION}.jar; \
    curl -fsSL "https://repo.maven.apache.org/maven2/org/apache/hadoop/hadoop-client-runtime/${HADOOP_VERSION}/hadoop-client-runtime-${HADOOP_VERSION}.jar" \
      -o /opt/flink/lib/hadoop-client-runtime-${HADOOP_VERSION}.jar
