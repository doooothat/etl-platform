# 🚀 Modern ETL Platform (Local Lakehouse)

This project provides a local development environment for a modern Data Lakehouse architecture combining **Airflow**, **Spark**, **Trino**, **Nessie**, **Iceberg**, **MinIO**, **Superset**, **Kafka**, and **Vector**.

---

## 🏗️ Architecture Overview
This platform simulates a real-world enterprise data stack including:
- **Batch ETL**: Airflow -> Spark -> Iceberg -> MinIO
- **Real-time Streaming**: Pod Logs -> Vector -> Kafka -> Spark Streaming -> Iceberg
- **Query & Analytics**: Trino -> Iceberg -> Superset
- **Monitoring**: Prometheus -> Grafana

---

## 🛠️ Prerequisites & Configuration
Before starting the platform, you **MUST** configure your local environment variables.

### 1. Configure `local.env` (Mandatory)
```bash
cp env.example local.env
# Edit local.env and set PROJECT_ROOT to your absolute project path
```

---

## ⚡ Quick Start

### 1. Start Support Services
```bash
./manage-project.sh start
```

### 2. Check Status
```bash
./manage-project.sh status
```

### 3. Monitoring Log Flow
Once started, you can see real-time logs landing in Kafka via **Kafka UI**: [http://localhost:9080](http://localhost:9080)

---

## 🎨 Core Components & URLs

| Component | Port | Local URL |
| :--- | :--- | :--- |
| **Airflow** (UI) | 8080 | [http://localhost:8080](http://localhost:8080) |
| **Superset** (BI) | 8088 | [http://localhost:8088](http://localhost:8088) |
| **Kafka UI** (Log) | 9080 | [http://localhost:9080](http://localhost:9080) |
| **Trino** (Query) | 18080 | [http://localhost:18080](http://localhost:18080) |
| **Grafana** (Dash) | 3000 | [http://localhost:3000](http://localhost:3000) |
| **MinIO** (S3) | 9001 | [http://localhost:9001](http://localhost:9001) |

---

## 📝 Key Features
- **Real-time Log Collection**: Vector collects all K8s logs and buffers them in **Apache Kafka 3.9 (KRaft)**.
- **FIFO Data Retention**: Logic-based cleanup (500MB / 2hr) to prevent local disk exhaustion.
- **Dynamic Path Injection**: The `manage-project.sh` dynamically injects local roots into container mounts.
- **No PVC Policy**: All temporary data is memory-backed or ephemeral for zero-residue development.

---

## ✅ Verified Environment
- **OS**: macOS (M4/M3/M2/M1 & Intel)
- **Container / K8s**: [OrbStack](https://orbstack.dev/) (K3s engine recommended)
- **RAM**: 8GB+ allocated (Platform uses ~12GB peak during full processing)

---
> **Learn More**: See [overview.md](./overview.md) for detailed architecture diagrams and component roles.
