---
name: contributing-to-weaviate-local-k8s
description: Expert knowledge for contributing to and reviewing weaviate-local-k8s code. Covers bash script architecture, Helm values generation, Kind cluster management, GitHub Actions integration, and testing patterns. Use when implementing features, reviewing PRs, fixing bugs, or improving test coverage in the weaviate-local-k8s repository.
---

# Contributing to and Reviewing weaviate-local-k8s

Expert context for developing features, reviewing code, and maintaining quality in the weaviate-local-k8s repository.

## Repository Architecture

### Key Files

| File | Purpose | Lines |
|------|---------|-------|
| `local-k8s.sh` | Main entry point. Defines env vars, orchestrates setup/upgrade/clean | ~400 |
| `utilities/helpers.sh` | All helper functions (helm values, port forwarding, health checks) | ~1070 |
| `action.yml` | GitHub Actions composite action definition | ~200 |
| `.github/workflows/main.yml` | CI test matrix (12 test jobs) | ~870 |

### Data Flow: Env Var to Cluster

```
User sets env vars (RBAC=true, REPLICAS=3, etc.)
    -> local-k8s.sh reads defaults, validates
    -> setup() called
        -> verify_ports_available()
        -> Kind cluster created (kind create cluster)
        -> Namespace created (kubectl create namespace weaviate)
        -> Dependent services started (MinIO, Keycloak, Prometheus, Dash0)
        -> setup_helm() configures Helm chart source
        -> generate_helm_values() translates env vars to --set flags
        -> helm upgrade --install with generated values
        -> Wait for StatefulSet readyReplicas
        -> port_forward_to_weaviate() sets up kubectl-relay
        -> port_forward_weaviate_pods() creates per-pod services + forwarding
        -> wait_weaviate() + wait_for_all_healthy_nodes()
        -> wait_for_raft_sync() verifies cluster consensus
```

### Function Map (helpers.sh)

**Core:**
- `generate_helm_values()` - Translates all env vars to Helm `--set` flags. This is the most critical function.
- `setup_helm()` - Configures Helm chart source (repo or branch clone)
- `port_forward_to_weaviate()` - Installs kubectl-relay, forwards service ports
- `port_forward_weaviate_pods()` - Creates per-pod K8s services, forwards individual pod ports

**Health checks:**
- `wait_weaviate()` - Polls `/` until Weaviate responds
- `wait_for_all_healthy_nodes()` - Polls `/v1/nodes` until all HEALTHY
- `wait_for_raft_sync()` - Polls `/v1/cluster/statistics` until synchronized
- `is_statistics_synced_for_port()` - Checks sync status on a specific port

**Auth-aware helpers:**
- `curl_with_auth()` - Wraps curl with Bearer token when auth enabled
- `is_auth_enabled()` - Checks STS env or ConfigMap for auth state
- `get_bearer_token()` - Extracts first API key from STS env or ConfigMap

**Service lifecycle:**
- `startup_minio()` / `shutdown_minio()` / `wait_for_minio()`
- `startup_keycloak()` / `wait_for_keycloak()`
- `setup_monitoring()` / `wait_for_monitoring()`
- `setup_dash0()` / `wait_for_dash0()`

**Utilities:**
- `verify_ports_available()` - Pre-flight port check
- `use_local_images()` - Pulls + loads Docker images into Kind
- `log_raft_sync_debug_info()` - Debug dump on Raft timeout
- `start/stop_weaviate_pod_state_logger()` - Background pod state tracking

## Adding a New Feature

### Checklist

1. **Add env var** in `local-k8s.sh` with default value (`VAR=${VAR:-"default"}`)
2. **Add Helm values** in `generate_helm_values()` in `helpers.sh`
3. **Add service lifecycle** if the feature needs a new service (startup/wait/shutdown functions)
4. **Add to setup()** flow in `local-k8s.sh` (ordering matters: services before Helm install)
5. **Add to upgrade()** if applicable
6. **Add GitHub Action input** in `action.yml` with matching env mapping
7. **Add CI test** in `.github/workflows/main.yml`
8. **Update skill documentation** in `.claude/skills/operating-weaviate-local-k8s/`

### Example: Adding a New Feature Flag

```bash
# 1. In local-k8s.sh, add default:
MY_FEATURE=${MY_FEATURE:-"false"}

# 2. In helpers.sh generate_helm_values(), add conditional:
if [[ $MY_FEATURE == "true" ]]; then
    helm_values="${helm_values} --set my.feature.enabled=true"
fi

# 3. In action.yml, add input:
#   my-feature:
#     description: 'Enable my feature'
#     required: false
#     default: 'false'
# And map in env section:
#   MY_FEATURE: ${{ inputs.my-feature }}

# 4. In main.yml, add to an existing test or create a new job
```

### Example: Adding a New Module

In `generate_helm_values()`:
```bash
if [[ $MODULE == "my-new-module" ]]; then
    helm_values="${helm_values} --set modules.my-new-module.enabled=\"true\""
    helm_values="${helm_values} --set modules.my-new-module.repo=org/image"
    helm_values="${helm_values} --set modules.my-new-module.tag=version"
    continue
fi
```

In `use_local_images()`, add case block:
```bash
"my-new-module")
    WEAVIATE_IMAGES+=("org/image:version")
    ;;
```

## Code Review Guidelines

### Critical Review Areas

1. **`generate_helm_values()` correctness**: Every `--set` flag must match the weaviate-helm chart values schema. Check https://github.com/weaviate/weaviate-helm
2. **Port conflicts**: New services must not collide with existing ports. Check `verify_ports_available()`.
3. **Feature dependencies**: Validate prerequisites (e.g., `USAGE_S3` requires `ENABLE_RUNTIME_OVERRIDES`)
4. **Auth-awareness**: Any new HTTP call to Weaviate must use `curl_with_auth()`, not raw `curl`
5. **Cleanup in `clean()`**: New services must be cleaned up properly
6. **Idempotency**: `setup()` and `upgrade()` should handle re-runs gracefully
7. **Error handling**: `set -eou pipefail` is active. Failed commands exit immediately.
8. **action.yml parity**: Every env var must have a matching action input

### Common Mistakes

- Forgetting to add `--local-images` handling for new image dependencies
- Not updating timeout calculation in `get_timeout()` for new services
- Missing port forwarding for new services
- Auth config: `rbac` and `admin_list` are mutually exclusive
- Using `curl` directly instead of `curl_with_auth()` in health checks
- Not handling the `HELM_BRANCH` path (local chart clone vs repo)

### Review Checklist

```
- [ ] Env var has default in local-k8s.sh
- [ ] Helm values generated correctly in generate_helm_values()
- [ ] Feature works with both --local-images and remote images
- [ ] Timeout calculation updated in get_timeout() if adding services
- [ ] Port forwarding added if service needs external access
- [ ] Clean function handles teardown
- [ ] action.yml input added with env mapping
- [ ] CI test added or existing test updated
- [ ] Works with RBAC enabled (auth-aware)
- [ ] Works with EXPOSE_PODS=true and false
- [ ] Documentation updated in skills
```

## Detailed References

- **Architecture deep-dive**: See [references/architecture.md](references/architecture.md) for file structure, function signatures, and naming conventions
- **GitHub Actions**: See [references/github-actions.md](references/github-actions.md) for CI matrix, action.yml schema, retry logic, and failure diagnostics
- **Helm integration**: See [references/helm-integration.md](references/helm-integration.md) for chart values, generate_helm_values() patterns, and weaviate-helm compatibility
- **Testing & quality**: See [references/testing-quality.md](references/testing-quality.md) for test coverage map, adding tests, and quality standards
- **Code review**: See [references/code-review.md](references/code-review.md) for detailed review checklist and anti-patterns
