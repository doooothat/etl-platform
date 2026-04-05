# 🚀 Modern ETL Platform (Local Lakehouse)

This project provides a local development environment for a modern Data Lakehouse architecture combining **Airflow**, **Spark**, **Trino**, **Nessie**, **Iceberg**, **MinIO**, and **Superset**.

---

## 🛠️ Prerequisites & Configuration

Before starting the platform, you **MUST** configure your local environment variables for the management script.

### 1. Configure `local.env` (Mandatory)
Copy the example environment file and set your absolute project path. This file is excluded from Git (configured in `.gitignore`) to protect your local environment details.

```bash
# Copy template
cp env.example local.env

# Edit local.env
nano local.env
```

**Required Variable:**
- `PROJECT_ROOT`: The **absolute path** to this project root directory on your machine.
    - Example: `PROJECT_ROOT=/Users/yourname/work/etl-platform`
    - *Note: This is used for mounting local DAGs into the Airflow container.*

---

## ⚡ Quick Start

### 1. Start Support Services
The management script handles everything from dependency-ordered startup to initial data loading.

```bash
./manage-project.sh start
```

### 2. Check Status
Verify that all components are running correctly.

```bash
./manage-project.sh status
```

### 3. Stop System
Scale down all workloads and clean up ephemeral storage (PVCs).

```bash
./manage-project.sh stop
```

---

## 🎨 Core Components & URLs

| Component | Port | Local URL |
| :--- | :--- | :--- |
| **Airflow** (UI) | 8080 | [http://localhost:8080](http://localhost:8080) |
| **Superset** (BI) | 8088 | [http://localhost:8088](http://localhost:8088) |
| **Trino** (Query) | 18080 | [http://localhost:18080](http://localhost:18080) |
| **Grafana** (Dash) | 3000 | [http://localhost:3000](http://localhost:3000) |
| **MinIO** (Storage) | 9001 | [http://localhost:9001](http://localhost:9001) |

---

## 📝 Key Features
- **Dynamic Path Injection**: The `manage-project.sh` dynamically injects your `PROJECT_ROOT` into Helm values for seamless local synchronization.
- **Granular Control**: Supports individual component management (`./manage-project.sh start airflow`, etc.).
- **Ephemeral Storage**: All DB/Storage are memory-backed or ephemeral for a clean local development experience.

---

## ✅ Verified Environment

The following environment has been verified to run the full platform stable:

- **OS**: macOS (Apple Silicon / Intel)
- **Container / K8s**: [OrbStack](https://orbstack.dev/) (v1.5.0+)
    - *Note: Integrated K3s engine is recommended for lightweight local operation.*
- **Cluster Specs**:
    - **RAM**: Minimum 4GB+ allocated to OrbStack (8GB+ recommended)
    - **CPU**: 4 Cores+ allocated
- **Command Line Tools**:
    - **Helm**: v3.12+
    - **Kubectl**: v1.28+
    - **Shell**: Bash / Zsh (MacOS Default)

---
> **Tip**: If `local.env` is not present, the script defaults to the current working directory (`$(pwd)`). However, explicitly setting `PROJECT_ROOT` is recommended for stability.
