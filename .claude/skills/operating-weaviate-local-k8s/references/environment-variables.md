# Environment Variables Reference

Complete reference for all environment variables supported by weaviate-local-k8s.

## Required

| Variable | Description |
|----------|-------------|
| `WEAVIATE_VERSION` | Weaviate version to deploy (e.g., `"1.28.0"`, `"latest"`) |

## Cluster Topology

| Variable | Default | Description |
|----------|---------|-------------|
| `WORKERS` | `""` (empty) | Kind worker nodes. Empty/0 = control-plane only |
| `REPLICAS` | `1` | Weaviate pod replicas. Must be <= total nodes |
| `CLUSTER_NAME` | `"weaviate-local-cluster"` | Kind cluster name, used for Dash0 identification |

Rule: `WORKERS >= REPLICAS - 1` (control-plane counts as a node).

## Network Ports

### Configurable

| Variable | Default | Description |
|----------|---------|-------------|
| `WEAVIATE_PORT` | `8080` | HTTP REST API |
| `WEAVIATE_GRPC_PORT` | `50051` | gRPC API |
| `WEAVIATE_METRICS` | `2112` | Prometheus metrics endpoint |
| `PROFILER_PORT` | `6060` | Go pprof profiler |
| `MINIO_PORT` | `9000` | MinIO S3 API (when backup/offload enabled) |

### Fixed (not configurable)

| Port | Service |
|------|---------|
| `9091` | Prometheus |
| `3000` | Grafana |
| `9090` | Keycloak (OIDC) |

### Per-Pod Ports (when EXPOSE_PODS=true)

Pod N gets: HTTP=`WEAVIATE_PORT+(N+1)`, gRPC=`WEAVIATE_GRPC_PORT+(N+1)`, Metrics=`WEAVIATE_METRICS+(N+1)`, Profiler=`PROFILER_PORT+(N+1)`.

## Helm Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `HELM_TIMEOUT` | `"10m"` | Timeout for helm install/upgrade |
| `HELM_REPO_UPDATE_TIMEOUT` | `"5m"` | Timeout for helm repo update |
| `HELM_BRANCH` | `""` | Specific weaviate-helm branch. Empty = released chart |
| `VALUES_INLINE` | `""` | Additional `--set` flags appended last |

## Feature Flags

All are string `"true"` / `"false"`.

| Variable | Default | Description | Dependencies |
|----------|---------|-------------|--------------|
| `OBSERVABILITY` | `"true"` | Prometheus + Grafana stack | |
| `EXPOSE_PODS` | `"true"` | Per-pod port forwarding | |
| `ENABLE_BACKUP` | `"false"` | S3 backup and collection export via MinIO | Deploys MinIO |
| `S3_OFFLOAD` | `"false"` | Tenant offloading to S3 | Deploys MinIO |
| `USAGE_S3` | `"false"` | Usage metrics in S3 | Requires `ENABLE_RUNTIME_OVERRIDES=true` |
| `ENABLE_RUNTIME_OVERRIDES` | `"false"` | Dynamic config reloading (30s interval) | |
| `RBAC` | `"false"` | Role-Based Access Control | Default: admin-user/admin-key |
| `OIDC` | `"false"` | OpenID Connect via Keycloak | Deploys Keycloak |
| `DYNAMIC_USERS` | `"false"` | Runtime user management | |
| `DASH0` | `"false"` | Dash0 observability platform | Requires `DASH0_TOKEN` |
| `DEBUG` | `"false"` | Enables `set -x` in scripts | |
| `DELETE_STS` | `"false"` | Delete StatefulSet on upgrade (destructive) | |

## Images and Modules

| Variable | Default | Description |
|----------|---------|-------------|
| `WEAVIATE_IMAGE_PREFIX` | `"semitechnologies"` | Docker registry prefix |
| `MODULES` | `""` | Comma-separated module list |
| `DOCKER_CONFIG` | `""` | Docker config file for pull secrets (absolute path, no `~`) |

## Authentication

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTH_CONFIG` | `""` | Path to YAML auth config file. Overrides default RBAC/OIDC settings |

## Dash0

| Variable | Default | Description |
|----------|---------|-------------|
| `DASH0_TOKEN` | `""` | Authorization token (required when `DASH0=true`) |
| `DASH0_ENDPOINT` | `"ingress.eu-west-1.aws.dash0.com:4317"` | Export endpoint |
| `DASH0_API_ENDPOINT` | `"api.eu-west-1.aws.dash0.com"` | API endpoint |

## Runtime Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `RUNTIME_OVERRIDES_PATH` | `"/config/overrides.yaml"` | Container-internal path for overrides ConfigMap |

## Dependency Rules

1. `USAGE_S3=true` requires `ENABLE_RUNTIME_OVERRIDES=true`
2. `DASH0=true` requires `DASH0_TOKEN`
3. `AUTH_CONFIG` file must exist at path
4. `DOCKER_CONFIG` must be absolute path (no `~` expansion)
5. Any of `ENABLE_BACKUP`, `S3_OFFLOAD`, `USAGE_S3` being `true` triggers MinIO deployment
6. `rbac` and `admin_list` are mutually exclusive in Helm auth config
