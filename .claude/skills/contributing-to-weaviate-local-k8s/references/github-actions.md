# GitHub Actions Integration

CI matrix, action.yml schema, retry logic, and failure diagnostics.

## action.yml Structure

The composite action (`action.yml`) exposes all env vars as action inputs with matching names:

```yaml
inputs:
  operation:           # setup (default), upgrade, clean
  weaviate-version:    # -> WEAVIATE_VERSION
  workers:             # -> WORKERS (default: '0')
  replicas:            # -> REPLICAS (default: '1')
  weaviate-port:       # -> WEAVIATE_PORT (default: '8080')
  weaviate-grpc-port:  # -> WEAVIATE_GRPC_PORT (default: '50051')
  modules:             # -> MODULES (default: '')
  helm-branch:         # -> HELM_BRANCH (default: '')
  enable-backup:       # -> ENABLE_BACKUP (default: 'false')
  s3-offload:          # -> S3_OFFLOAD (default: 'false')
  usage-s3:            # -> USAGE_S3 (default: 'false')
  delete-sts:          # -> DELETE_STS (default: 'false')
  values-inline:       # -> VALUES_INLINE (default: '')
  values-override:     # -> Creates values-override.yaml from string content
  observability:       # -> OBSERVABILITY (default: 'true')
  dash0:               # -> DASH0 (default: 'false')
  cluster-name:        # -> CLUSTER_NAME
  dash0-token:         # -> DASH0_TOKEN
  dash0-endpoint:      # -> DASH0_ENDPOINT
  dash0-api-endpoint:  # -> DASH0_API_ENDPOINT
  expose-pods:         # -> EXPOSE_PODS (default: 'true')
  rbac:                # -> RBAC (default: 'false')
  oidc:                # -> OIDC (default: 'false')
  dynamic-users:       # -> DYNAMIC_USERS (default: 'false')
  auth-config:         # -> AUTH_CONFIG (default: '')
  debug:               # -> DEBUG (default: 'false')
  enable-runtime-overrides: # -> ENABLE_RUNTIME_OVERRIDES
  docker-config:       # -> DOCKER_CONFIG
```

### Special Input: values-override

Unlike other inputs, `values-override` creates a file rather than mapping to an env var:

```yaml
- name: Create values-override.yaml
  if: ${{ inputs.values-override != '' }}
  run: echo "${{ inputs.values-override }}" > ${{ github.action_path }}/values-override.yaml
```

### Retry Logic

The composite action includes automatic retry:

```yaml
MAX_RETRIES=2
RETRY_DELAY=30

for attempt in $(seq 1 $MAX_RETRIES); do
  if ${{ github.action_path }}/local-k8s.sh $OPERATION; then
    exit 0
  else
    if [ $attempt -lt $MAX_RETRIES ]; then
      sleep $RETRY_DELAY
      if [ "$OPERATION" = "setup" ]; then
        ${{ github.action_path }}/local-k8s.sh clean || true
      fi
    fi
  fi
done
```

### Failure Diagnostics

On failure, the action dumps:
- Weaviate pod logs
- Node status (`kubectl get nodes -o wide`)
- Pod status (`kubectl get pods -o wide`)
- K8s events (`kubectl get events`)
- StatefulSet config (`kubectl get sts -o yaml`)
- kubectl-relay processes

## CI Test Matrix (main.yml)

### Test Jobs

| Job | Description | Key Params |
|-----|-------------|------------|
| `run-weaviate-local-k8s-basic` | Basic 5-node cluster | WORKERS=3, REPLICAS=5, EXPOSE_PODS=false |
| `run-weaviate-local-k8s-all-params` | All parameters | 6 replicas, all features enabled |
| `run-weaviate-local-k8s-which-fails` | Failure case (bad image) | WEAVIATE_VERSION='idontexist' |
| `run-weaviate-local-k8s-with-module` | Modules | text2vec-contextionary + model2vec |
| `run-weaviate-local-k8s-raft-upgrade` | Raft upgrade | 1.24.9 -> 1.25.0 |
| `run-weaviate-local-k8s-raft-downgrade` | Raft downgrade | 1.25.0 -> 1.24.9 |
| `run-weaviate-local-k8s-upgrade-to-latest` | Upgrade to latest | 1.26.0 -> latest |
| `run-weaviate-local-k8s-backup` | Backup functionality | ENABLE_BACKUP=true |
| `run-weaviate-local-k8s-clean` | Clean operation | Verify cleanup works |
| `run-weaviate-local-k8s-single-node` | Single node | WORKERS=0, REPLICAS=1 |

### Common Verification Pattern

Each test job verifies:
1. Correct replica count (`kubectl get sts`)
2. Correct worker count (`kubectl get nodes`)
3. Correct version (`curl /v1/nodes`)
4. Metrics endpoint accessible (`curl :2112/metrics`)
5. Feature-specific checks (OIDC, ports, modules, etc.)

### Adding a New CI Test

```yaml
run-weaviate-local-k8s-new-feature:
  needs: get-latest-weaviate-version
  runs-on: ubuntu-latest
  name: Test new feature
  env:
    WORKERS: '2'
    REPLICAS: '3'
    WEAVIATE_VERSION: ${{ needs.get-latest-weaviate-version.outputs.LATEST_WEAVIATE_VERSION }}
    NEW_FEATURE: 'true'
  steps:
    - name: Checkout
      uses: actions/checkout@v2
    - name: Deploy
      uses: ./
      with:
        workers: ${{ env.WORKERS }}
        replicas: ${{ env.REPLICAS }}
        weaviate-version: ${{ env.WEAVIATE_VERSION }}
        new-feature: ${{ env.NEW_FEATURE }}
    - name: Verify
      run: |
        set -ex
        # Verify feature-specific behavior
        kubectl get sts weaviate -n weaviate -o=jsonpath='{.status.readyReplicas}'
```

## Adding action.yml Inputs

When adding a new feature, add to action.yml:

```yaml
# 1. Add input definition
inputs:
  new-feature:
    description: 'Enable new feature'
    required: false
    default: 'false'

# 2. Add env mapping in runs.steps[].env
env:
  NEW_FEATURE: ${{ inputs.new-feature }}
```
