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
COLLECTION_EXPORT=true \
./local-k8s.sh setup
```

`COLLECTION_EXPORT=true` enables the `collectionExport` Helm feature (`collectionExport.enabled=true`, `EXPORT_DEFAULT_BUCKET=weaviate-export`). MinIO is started automatically and the `weaviate-export` bucket is created.

Collection export uses the backup-s3 module as its S3 backend. If `ENABLE_BACKUP=true` is not also set, the backup-s3 module is automatically configured to point to MinIO (no user action needed). Test with `weaviate-cli`:

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

## Operator Deployment (DEPLOYMENT_METHOD=operator)

Deploys Weaviate through the wcs-weaviate-operator instead of the helm chart:
cert-manager is installed (operator webhooks), the operator is installed from
`dist/install.yaml` of the resolved sources, and a `Weaviate` CR
(`database.weaviate.io/v1alpha1`) named `weaviate` is applied. Resource names
match the helm chart (`sts/weaviate`, `svc/weaviate`, `svc/weaviate-grpc`), so
ports, health checks and `EXPOSE_PODS` behave identically.

```bash
# From main (clone + docker build; private repo: needs GH_TOKEN or SSH OPERATOR_REPO)
DEPLOYMENT_METHOD=operator WEAVIATE_VERSION="1.36.8" REPLICAS=3 ./local-k8s.sh setup

# From a local checkout / a pre-built image
DEPLOYMENT_METHOD=operator OPERATOR_DIR=~/repos/wcs-weaviate-operator WEAVIATE_VERSION="1.36.8" ./local-k8s.sh setup
DEPLOYMENT_METHOD=operator OPERATOR_IMAGE="wcs-weaviate-operator:pr-7" WEAVIATE_VERSION="1.36.8" ./local-k8s.sh setup

# Upgrade: version change (via Upgrade CRD) + config reconcile
DEPLOYMENT_METHOD=operator WEAVIATE_VERSION="1.38.0" REPLICAS=3 ./local-k8s.sh upgrade

# Scale up (same version): just pass a larger, valid REPLICAS (1 or odd >= 3)
DEPLOYMENT_METHOD=operator WEAVIATE_VERSION="1.38.0" REPLICAS=5 RBAC=true ./local-k8s.sh upgrade

# Upgrade with a pre-upgrade backup (needs ENABLE_BACKUP=true for an s3 backend)
DEPLOYMENT_METHOD=operator WEAVIATE_VERSION="1.38.0" REPLICAS=3 \
  ENABLE_BACKUP=true OPERATOR_UPGRADE_BACKUP=true ./local-k8s.sh upgrade
```

### Operator-mode upgrades (config/scaling + Upgrade CRD)

`upgrade` in operator mode does two things, mirroring the helm path while honoring
the operator's mechanisms:

1. **Config + scaling** — it re-applies the Weaviate CR (replicas, auth, backup,
   modules, resources, `cr-override.yaml`), but pins `spec.version` to the
   currently-running version so this apply never changes the version.
2. **Version** — if the requested `WEAVIATE_VERSION` differs from the running one,
   it then creates an `Upgrade` resource (`database.weaviate.io/v1alpha1`, named
   `weaviate-upgrade-<version>`), the operator's canonical mechanism: blocks
   downgrades, optionally backs up, patches the version and waits for every pod to
   be healthy at the new version. The script polls `Upgrade.status.phase` to
   `Success` (aborts on `Failed`/`Cancelled`).

**Scaling is supported, but scale-UP only.** The operator's webhook rejects
reducing replicas (`you cannot downscale a weaviate instance`); weaviate-local-k8s
detects a downscale request and fails fast — recreate the cluster (`clean` +
`setup`) to shrink. Replicas must be 1 or an odd number >= 3.

Backups are off by default (`skipBackups: true`). `OPERATOR_UPGRADE_BACKUP=true`
flips `skipBackups` to false and sets `backend: s3`, which requires a configured
backup backend (`ENABLE_BACKUP=true`, i.e. MinIO). Verify:

```bash
kubectl get weaviate weaviate -n weaviate -o jsonpath='{.spec.replicas}'        # new replica count
kubectl get upgrades.database.weaviate.io -n weaviate
kubectl get upgrade -n weaviate -o jsonpath='{.items[0].status.phase}'        # Success
kubectl get upgrade -n weaviate -o jsonpath='{.items[0].status.lastBackupName}' # set when backed up
```

### Local vectorizer modules in operator mode

The operator configures Weaviate to use a vectorizer but does not deploy the
companion inference server (the helm chart does). For `text2vec-transformers`
and `text2vec-model2vec`, weaviate-local-k8s deploys it itself from
`manifests/transformers-inference.yaml` / `manifests/model2vec-inference.yaml`
(same images as the helm path, so `--local-images` is reused) and wires the CR's
`spec.podConfig.extraEnv` to point Weaviate at the in-cluster service:

```bash
DEPLOYMENT_METHOD=operator MODULES="text2vec-transformers,text2vec-model2vec" \
  WEAVIATE_VERSION="1.37.0" REPLICAS=1 ./local-k8s.sh setup
```

Resources live in the `weaviate` namespace, so `clean()` removes them with it.
Other modules requiring a companion deployment are enabled in the CR but stay
non-functional (warned at setup).

Verification additions on top of the standard checks:

```bash
kubectl get weaviate weaviate -n weaviate                      # CR status/conditions
kubectl get secret weaviate-operator-admin-key -n weaviate \
  -o jsonpath='{.data.key}' | base64 --decode                  # generated admin key
kubectl logs -n wcs-weaviate-operator-system deployment/wcs-weaviate-operator-controller-manager
kubectl rollout status deployment/transformers-inference -n weaviate  # local vectorizer (if enabled)
kubectl rollout status deployment/model2vec-inference -n weaviate     # local vectorizer (if enabled)
```

Constraints: REPLICAS 1 or odd >= 3; helm-only options rejected; customize the CR
via `cr-override.yaml` (deep-merged). See the SKILL.md Operator Deployment section.
