# Architecture Deep-Dive

File structure, function signatures, naming conventions, and data flow.

## File Structure

```
weaviate-local-k8s/
  local-k8s.sh          # Main entry point (~400 lines)
  utilities/
    helpers.sh           # All helper functions (~1070 lines)
  action.yml             # GitHub Actions composite action (~200 lines)
  .github/workflows/
    main.yml             # CI test matrix (~870 lines)
  manifests/
    minio-dev.yaml                # MinIO deployment manifest
    keycloak.yaml                 # Keycloak deployment manifest
    keycloak-weaviate-realm.json  # Keycloak realm config for OIDC
    grafana-renderer.yaml         # Grafana renderer deployment
    metrics-server.yaml           # Metrics server deployment
    grafana-dashboards/           # 15+ Grafana dashboard JSON files
  scripts/
    create_oidc_user.sh  # Create Keycloak user
    get_user_token.sh    # Get OIDC bearer token
    create_oidc_group.sh # Create Keycloak group
```

## Data Flow: Env Var to Cluster

```
User sets env vars (RBAC=true, REPLICAS=3, etc.)
    -> local-k8s.sh reads defaults (VAR=${VAR:-"default"})
    -> validates dependencies (e.g., USAGE_S3 requires ENABLE_RUNTIME_OVERRIDES)
    -> setup() called
        -> verify_ports_available()
        -> Kind cluster created (kind create cluster --config /tmp/kind-config.yaml)
        -> Namespace created (kubectl create namespace weaviate)
        -> Dependent services started (MinIO, Keycloak, Prometheus, Dash0)
        -> setup_helm() configures Helm chart source
        -> generate_helm_values() translates env vars to --set flags
        -> helm upgrade --install with generated values + overrides
        -> Wait for StatefulSet readyReplicas
        -> port_forward_to_weaviate() sets up kubectl-relay
        -> port_forward_weaviate_pods() creates per-pod services + forwarding
        -> wait_weaviate() + wait_for_all_healthy_nodes()
        -> wait_for_raft_sync() verifies cluster consensus
```

## local-k8s.sh Structure

**Lines 1-60**: Env var defaults (all `VAR=${VAR:-"default"}` pattern)

**Lines 61-89**: Conditional logic (`need_minio`, `get_timeout()`)

**Lines 91-161**: `upgrade()` function
- Sets kubectl context
- Handles `--local-images` flag
- Calls `setup_helm`, `generate_helm_values`
- `helm upgrade` with values
- Waits for readyReplicas, port forwarding, health checks

**Lines 164-313**: `setup()` function
- Port verification, Kind config generation
- Kind cluster creation
- Service startups (MinIO, Keycloak)
- Helm chart setup and install
- Health checks and status reporting

**Lines 315-350**: `clean()` function
- Kills kubectl-relay processes
- Helm uninstall, namespace delete
- Kind cluster delete

**Lines 352-406**: Main script (argument parsing, requirements check)

## helpers.sh Function Map

### Core Functions

| Function | Purpose | Called From |
|----------|---------|-------------|
| `generate_helm_values()` | Translates ALL env vars to Helm `--set` flags | setup(), upgrade() |
| `setup_helm()` | Configures Helm chart (repo or branch clone) | setup(), upgrade() |
| `port_forward_to_weaviate()` | Installs kubectl-relay, forwards service ports | setup(), upgrade() |
| `port_forward_weaviate_pods()` | Creates per-pod K8s services, forwards pod ports | setup(), upgrade() |

### Health Check Functions

| Function | Purpose | Endpoint |
|----------|---------|----------|
| `wait_weaviate()` | Polls until Weaviate responds | `/` |
| `wait_for_all_healthy_nodes()` | Polls until all nodes HEALTHY | `/v1/nodes` |
| `wait_for_raft_sync()` | Polls until cluster synchronized | `/v1/cluster/statistics` |
| `is_statistics_synced_for_port()` | Checks sync on specific port | `/v1/cluster/statistics` |

### Auth-Aware Helpers

| Function | Purpose |
|----------|---------|
| `curl_with_auth()` | Wraps curl with Bearer token when auth enabled |
| `is_auth_enabled()` | Checks STS env or ConfigMap for auth state |
| `get_bearer_token()` | Extracts first API key from STS env or ConfigMap |

### Service Lifecycle Functions

| Function | Purpose |
|----------|---------|
| `startup_minio()` / `shutdown_minio()` / `wait_for_minio()` | MinIO S3 |
| `startup_keycloak()` / `wait_for_keycloak()` | Keycloak OIDC |
| `setup_monitoring()` / `wait_for_monitoring()` | Prometheus + Grafana |
| `setup_dash0()` / `wait_for_dash0()` | Dash0 operator |

### Utility Functions

| Function | Purpose |
|----------|---------|
| `verify_ports_available()` | Pre-flight port check |
| `use_local_images()` | Pulls + loads Docker images into Kind |
| `log_raft_sync_debug_info()` | Debug dump on Raft timeout |
| `start/stop_weaviate_pod_state_logger()` | Background pod state tracking |
| `echo_green/yellow/red()` | Colored output helpers |
| `show_help()` | CLI help text |

## Naming Conventions

- **Env vars**: `UPPER_SNAKE_CASE` (e.g., `WEAVIATE_PORT`, `ENABLE_BACKUP`)
- **Functions**: `lower_snake_case` (e.g., `generate_helm_values`, `wait_for_minio`)
- **Helm flags**: dot-notation (e.g., `--set image.tag=1.28.0`)
- **K8s resources**: kebab-case (e.g., `weaviate-headless`, `minio-dev`)
- **Ports**: base + offset pattern (service=8080, pod0=8081, pod1=8082, ...)

## Error Handling

- `set -eou pipefail` active globally (exit on any error)
- Service startups use `|| true` for idempotency
- Timeouts calculated dynamically via `get_timeout()`
- Failed commands exit immediately (no retry in script, retry in action.yml)
