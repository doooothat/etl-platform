# ==============================================================================
# Stage 1: Build Nessie Spark 4.0 Extensions from Source
# ==============================================================================
FROM eclipse-temurin:21-jdk-jammy AS builder

# Install Git
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Set up workspace
WORKDIR /workspace
ENV NESSIE_VERSION=nessie-0.107.4
ENV SPARK_MODULE=:nessie-spark-extensions-4.0_2.13

# Clone the exact version of Project Nessie (Shallow clone for speed)
RUN git clone --depth 1 -b ${NESSIE_VERSION} https://github.com/projectnessie/nessie.git .

# Build ONLY the Spark 4.0 extension JAR (skipping tests to save time)
# Note: Gradle will automatically download all required build dependencies
RUN ./gradlew ${SPARK_MODULE}:jar -x test --no-daemon

# ==============================================================================
# Stage 2: Create the Custom Apache Spark 4.0.2 Image
# ==============================================================================
FROM apache/spark:4.0.2

# Switch to root to modify system files (/opt/spark/jars)
USER root

# Copy the forged JAR from the 'builder' stage into Spark's library path
# Path structure is specific to Nessie's Gradle configuration
COPY --from=builder \
    /workspace/integrations/spark-extensions/v4.0/build/2.13/libs/nessie-spark-extensions-4.0_2.13-0.107.4.jar \
    /opt/spark/jars/

# Ensure proper file permissions so the spark user can read the JAR
RUN chmod 644 /opt/spark/jars/nessie-spark-extensions-4.0_2.13-0.107.4.jar

# Revert to the default non-root user for security
USER spark
