# Deployment Patterns

Advanced Helm configuration and deployment scenarios.

## Helm Configuration

### Using Helm Branch

Test unreleased Helm chart changes:

```bash
HELM_BRANCH="main" WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup
```

Clones weaviate-helm repository and uses local chart instead of published chart. Use for testing Helm chart PRs or experimental features.

### Inline Helm Values

Add custom Helm values via `VALUES_INLINE`:

```bash
WEAVIATE_VERSION="1.28.0" \
VALUES_INLINE="--set resources.requests.memory=4Gi --set resources.limits.memory=8Gi" \
./local-k8s.sh setup
```

Common patterns:

```bash
# Resource limits
VALUES_INLINE="--set resources.requests.cpu=2 --set resources.requests.memory=4Gi"

# Environment variables
VALUES_INLINE="--set env.LOG_LEVEL=debug --set env.QUERY_DEFAULTS_LIMIT=50"

# Storage class
VALUES_INLINE="--set storage.storageClassName=fast-ssd"

# Image registry
VALUES_INLINE="--set image.registry=cr.weaviate.io --set image.pullPolicy=Always"
```

### values-override.yaml

Create `values-override.yaml` in repository root for persistent overrides:

```yaml
resources:
  requests:
    cpu: 2
    memory: 4Gi
  limits:
    cpu: 4
    memory: 8Gi
env:
  LOG_LEVEL: debug
  QUERY_DEFAULTS_LIMIT: 100
persistence:
  size: 50Gi
```

Automatically detected and applied during deploy.

### Configuration Precedence

Precedence from lowest to highest:

1. **AUTH_CONFIG file** (applied via `-f` flag, lowest precedence)
2. **values-override.yaml** (applied via `-f` flag, overrides AUTH_CONFIG)
3. **Generated `--set` flags** (from script - replicas, auth, modules, etc., override all `-f` files)
4. **VALUES_INLINE `--set` flags** (appended last, highest precedence)

Note: Helm `--set` flags always override `-f` files regardless of position on the command line.

### Helm Timeouts

Recommended timeouts by scenario:
- Single node, no modules: 10m (default)
- Multi-node (3-5 replicas): 15m
- With heavy modules: 20m
- Slow network connection: 25m

## Deployment Scenarios

### Development (Fastest Startup)

```bash
WEAVIATE_VERSION="1.28.0" OBSERVABILITY=false EXPOSE_PODS=false ./local-k8s.sh setup
```

### Testing with Backup and Offload

```bash
WEAVIATE_VERSION="1.28.0" \
ENABLE_BACKUP=true S3_OFFLOAD=true ENABLE_RUNTIME_OVERRIDES=true \
./local-k8s.sh setup
```

Includes MinIO S3 (port 9000), backup bucket (`weaviate-backups`), tenant offloading, runtime override support.

### Multi-Node Production-Like

```bash
WORKERS=2 REPLICAS=3 WEAVIATE_VERSION="1.28.0" \
RBAC=true ENABLE_BACKUP=true OBSERVABILITY=true \
HELM_TIMEOUT="20m" VALUES_INLINE="--set resources.requests.memory=4Gi" \
./local-k8s.sh setup
```

### Module Testing

```bash
WEAVIATE_VERSION="1.28.0" \
MODULES="text2vec-transformers,generative-openai,reranker-cohere" \
HELM_TIMEOUT="20m" ./local-k8s.sh setup
```

Module images are large. Timeout automatically increases by 1200s.

### Collection Export Testing

```bash
WORKERS=2 REPLICAS=3 WEAVIATE_VERSION="1.37.0" \
ENABLE_BACKUP=true \
./local-k8s.sh setup
```

Collection export requires `ENABLE_BACKUP=true` (uses the same MinIO S3 backend as backups). Test with `weaviate-cli`:

```bash
weaviate-cli create export-collection --export_id my-export --backend s3 --wait --json
weaviate-cli get export-collection --export_id my-export --backend s3 --json
weaviate-cli cancel export-collection --export_id my-export --backend s3 --json
```

### MCP Server

Enable the MCP (Model Context Protocol) server for AI agent integration:

```bash
WEAVIATE_VERSION="1.28.0" MCP_ENABLED=true ./local-k8s.sh setup
```

MCP is a Weaviate-internal feature — no separate service or port forwarding needed. The server is accessible via the Weaviate REST endpoint at `http://localhost:8080/v1/mcp`.

Enable write access (object upsert) for full MCP capabilities:

```bash
WEAVIATE_VERSION="1.28.0" MCP_ENABLED=true MCP_WRITE_ACCESS_ENABLED=true ./local-k8s.sh setup
```

Verify: `curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/v1/mcp` (expect 200).

### CI/CD Pipeline

```bash
WEAVIATE_VERSION="1.28.0" OBSERVABILITY=false EXPOSE_PODS=true \
HELM_TIMEOUT="15m" ./local-k8s.sh setup
# Run tests...
./local-k8s.sh clean
```

## Local Image Loading

```bash
# Build Weaviate locally
cd /path/to/weaviate
docker build -t semitechnologies/weaviate:1.28.0-custom .

# Deploy using local image
cd "$WEAVIATE_LOCAL_K8S_DIR"
WEAVIATE_VERSION="1.28.0-custom" ./local-k8s.sh setup --local-images
```

Benefits: faster deployment, offline development, testing local builds, avoiding rate limits.

## Custom AUTH_CONFIG

### RBAC Configuration File

```yaml
authentication:
  anonymous_access:
    enabled: false
  apikey:
    enabled: true
    allowed_keys:
      - admin-key
      - user-key
    users:
      - admin-user
      - regular-user
authorization:
  rbac:
    enabled: true
    root_users:
      - admin-user
  admin_list:
    enabled: false  # Must be false when RBAC is enabled
```

**Important:** `rbac` and `admin_list` are mutually exclusive.

Deploy: `WEAVIATE_VERSION="1.28.0" RBAC=true AUTH_CONFIG="custom-auth.yaml" ./local-k8s.sh setup`

## Deployment Verification

```bash
# Check Helm release
helm list -n weaviate

# Get applied values
helm get values weaviate -n weaviate

# Check all resources
kubectl get all -n weaviate

# Verify environment variables
kubectl get sts weaviate -n weaviate -o jsonpath='{.spec.template.spec.containers[0].env[*]}' | jq -r '.name'
```
