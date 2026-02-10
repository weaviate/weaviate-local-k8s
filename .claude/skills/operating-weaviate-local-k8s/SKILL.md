---
name: operating-weaviate-local-k8s
description: Deploys, upgrades, and manages local Weaviate clusters in Kind (Kubernetes in Docker) using the weaviate-local-k8s tool. Determines optimal cluster configuration from requirements including version, replicas, modules, authentication, and features. Use when deploying Weaviate for testing, development, bug reproduction, CI/CD integration, or when the user describes a cluster scenario to set up.
---

# Operating Weaviate Local K8s Clusters

Deploy and manage local Weaviate clusters using the `local-k8s.sh` tool. This skill translates deployment requirements into the correct environment variables and commands.

`$WEAVIATE_LOCAL_K8S_DIR` refers to the weaviate-local-k8s repository root. Set it or `cd` into the repo before running commands.

## Quick Reference

```bash
# Setup
WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup

# Upgrade
WEAVIATE_VERSION="1.29.0" ./local-k8s.sh upgrade

# Clean (destructive, all data lost)
./local-k8s.sh clean
```

## Decision Guide

Given a scenario, determine which env vars to set:

### Cluster Size

| Scenario | WORKERS | REPLICAS |
|----------|---------|----------|
| Quick test / dev | 0 (default) | 1 (default) |
| Multi-node / HA | 2 | 3 |
| Stress / performance | 4 | 5 |

Rule: `WORKERS >= REPLICAS - 1` (control-plane counts as a node).

### Feature Selection

| Need | Env vars |
|------|----------|
| RBAC auth | `RBAC=true` |
| OIDC auth | `OIDC=true RBAC=true` |
| Dynamic users | `DYNAMIC_USERS=true RBAC=true` |
| S3 backups | `ENABLE_BACKUP=true` |
| Tenant offloading | `S3_OFFLOAD=true` |
| Usage metrics | `USAGE_S3=true ENABLE_RUNTIME_OVERRIDES=true` |
| Modules | `MODULES="text2vec-transformers"` |
| Fast startup (no monitoring) | `OBSERVABILITY=false` |
| Custom Helm chart | `HELM_BRANCH="main"` |
| Local images (offline/rate limits) | `./local-k8s.sh setup --local-images` |

### Timeout Estimation

```
timeout = (REPLICAS * 100s) + modules(1200s) + backup(100s) + observability(100s) + dash0(100s)
```

Override: `HELM_TIMEOUT="20m"`

## Common Deployment Patterns

### Basic Single-Node

```bash
WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup
```

Verify: `curl localhost:8080/v1/meta`

### Multi-Node HA Cluster

```bash
WORKERS=2 REPLICAS=3 WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup
```

Verify:
```bash
curl localhost:8080/v1/nodes | jq '.nodes[] | {name, status}'
curl localhost:8080/v1/cluster/statistics | jq '{synchronized, count: (.statistics | length)}'
```

### With RBAC

```bash
WEAVIATE_VERSION="1.28.0" RBAC=true ./local-k8s.sh setup
```

Default: user=`admin-user`, key=`admin-key` (root). Test: `curl -H "Authorization: Bearer admin-key" localhost:8080/v1/meta`

### With Modules

```bash
WEAVIATE_VERSION="1.28.0" MODULES="text2vec-transformers" HELM_TIMEOUT="20m" ./local-k8s.sh setup
```

Module images are large (~1-5GB). Timeout auto-increases by 1200s.

### With Backup (MinIO S3)

```bash
WEAVIATE_VERSION="1.28.0" ENABLE_BACKUP=true ./local-k8s.sh setup
```

MinIO on port 9000. Credentials: `aws_access_key` / `aws_secret_key`.

### Full-Featured

```bash
WORKERS=2 REPLICAS=3 WEAVIATE_VERSION="1.28.0" \
  MODULES="text2vec-transformers,generative-openai" \
  RBAC=true ENABLE_BACKUP=true S3_OFFLOAD=true \
  ENABLE_RUNTIME_OVERRIDES=true OBSERVABILITY=true \
  HELM_TIMEOUT="20m" ./local-k8s.sh setup
```

### Minimal (Fastest Startup)

```bash
WEAVIATE_VERSION="1.28.0" OBSERVABILITY=false ./local-k8s.sh setup
```

## Port Mapping

With `EXPOSE_PODS=true` (default), each replica gets dedicated ports:

| Type | Service | Pod 0 | Pod 1 | Pod N |
|------|---------|-------|-------|-------|
| HTTP | 8080 | 8081 | 8082 | 8080+(N+1) |
| gRPC | 50051 | 50052 | 50053 | 50051+(N+1) |
| Metrics | 2112 | 2113 | 2114 | 2112+(N+1) |
| Profiler | 6060 | 6061 | 6062 | 6060+(N+1) |

Additional: Prometheus=9091, Grafana=3000, Keycloak=9090, MinIO=9000.

## Verification Workflow

```bash
# 1. Pods running
kubectl get pods -n weaviate

# 2. Nodes healthy
curl localhost:8080/v1/nodes | jq '.nodes[] | {name, status}'

# 3. Raft synchronized (multi-node)
curl localhost:8080/v1/cluster/statistics | jq '{synchronized, count: (.statistics | length)}'

# 4. With RBAC
curl -H "Authorization: Bearer admin-key" localhost:8080/v1/meta
```

## Upgrade Workflow

```bash
# Standard upgrade (rolling, non-destructive)
WEAVIATE_VERSION="1.29.0" ./local-k8s.sh upgrade

# Upgrade with StatefulSet deletion (destructive, for major version jumps)
WEAVIATE_VERSION="1.29.0" DELETE_STS=true ./local-k8s.sh upgrade
```

The Kind cluster is NOT recreated. Only Weaviate pods are updated.

## Dependencies Between Features

1. `USAGE_S3=true` requires `ENABLE_RUNTIME_OVERRIDES=true`
2. `DASH0=true` requires `DASH0_TOKEN`
3. `AUTH_CONFIG` file must exist when provided
4. `DOCKER_CONFIG` must be absolute path (no `~`)
5. `rbac` and `admin_list` are mutually exclusive in auth configs

## Helm Values Precedence

Precedence from lowest to highest:
1. `AUTH_CONFIG` file (applied via `-f`, lowest precedence)
2. `values-override.yaml` (applied via `-f`, overrides AUTH_CONFIG)
3. Generated `--set` flags (from script logic, override all `-f` files)
4. `VALUES_INLINE` `--set` flags (appended last, highest precedence)

Note: Helm `--set` flags always override `-f` files regardless of position on the command line.

## Detailed References

- **Environment variables**: See [references/environment-variables.md](references/environment-variables.md) for complete env var reference (40+ variables)
- **Deployment patterns**: See [references/deployment-patterns.md](references/deployment-patterns.md) for advanced Helm configuration and scenarios
- **Authentication**: See [references/auth-config.md](references/auth-config.md) for RBAC, OIDC, custom AUTH_CONFIG, and dynamic users
- **Modules**: See [references/modules-config.md](references/modules-config.md) for module system, custom modules, and image management
- **Observability**: See [references/observability-config.md](references/observability-config.md) for Prometheus, Grafana, Dash0, and debugging
- **Troubleshooting**: See [references/troubleshooting.md](references/troubleshooting.md) for common issues and solutions
- **CLI integration**: See [references/cli-integration.md](references/cli-integration.md) for weaviate-cli configuration
