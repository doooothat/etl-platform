---
description: Stop all Kubernetes workloads for this project to save resources
---
// turbo
1. Scale down deployments and statefulsets to 0 in all project namespaces
```bash
./manage-project.sh stop
```
2. Verify that everything is stopped
```bash
./manage-project.sh status
```
