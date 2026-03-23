# Helm Integration

Chart values, generate_helm_values() patterns, and weaviate-helm compatibility.

## generate_helm_values()

This is the most critical function in the codebase. It translates ALL env vars to Helm `--set` flags. Located in `utilities/helpers.sh`.

### Structure

```bash
function generate_helm_values() {
    local helm_values=""

    # 1. Core settings (always set)
    helm_values="--set image.tag=${WEAVIATE_VERSION}"
    helm_values="${helm_values} --set replicas=${REPLICAS}"
    helm_values="${helm_values} --set image.repo=${WEAVIATE_IMAGE_PREFIX}/weaviate"

    # 2. Conditional feature blocks
    if [[ $RBAC == "true" ]]; then
        helm_values="${helm_values} --set ..."
    fi

    # 3. Module handling (loop over comma-separated MODULES)
    IFS=',' read -ra module_list <<< "$MODULES"
    for module in "${module_list[@]}"; do
        case "$module" in
            "text2vec-transformers")
                helm_values="${helm_values} --set modules.text2vec-transformers.enabled=\"true\""
                helm_values="${helm_values} --set modules.text2vec-transformers.tag=baai-bge-small-en-v1.5-onnx"
                ;;
            # ... other modules
        esac
    done

    # 4. AUTH_CONFIG file (applied via -f flag, not --set)
    if [[ -n "$AUTH_CONFIG" ]]; then
        helm_values="${helm_values} -f ${AUTH_CONFIG}"
    fi

    # 5. VALUES_INLINE (appended last, highest precedence)
    if [[ -n "$VALUES_INLINE" ]]; then
        helm_values="${helm_values} ${VALUES_INLINE}"
    fi

    echo "$helm_values"
}
```

### Adding a New Feature Flag

```bash
# Pattern: conditional --set block
if [[ $MY_FEATURE == "true" ]]; then
    helm_values="${helm_values} --set my.feature.enabled=true"
    helm_values="${helm_values} --set my.feature.setting=value"
fi
```

### Adding a New Module

```bash
# In the module loop case statement:
"my-new-module")
    helm_values="${helm_values} --set modules.my-new-module.enabled=\"true\""
    helm_values="${helm_values} --set modules.my-new-module.repo=org/image"
    helm_values="${helm_values} --set modules.my-new-module.tag=version"
    continue
    ;;
```

Also add to `use_local_images()`:
```bash
"my-new-module")
    WEAVIATE_IMAGES+=("org/image:version")
    ;;
```

## Helm Values Precedence

Applied in order by `helm upgrade --install`:

```bash
helm upgrade --install weaviate $TARGET \
    --namespace weaviate \
    --timeout $HELM_TIMEOUT \
    $HELM_VALUES \          # 1. Generated values (from generate_helm_values)
    $VALUES_OVERRIDE        # 2. values-override.yaml (if exists, via -f flag)
```

Within `generate_helm_values()`:
- AUTH_CONFIG applied via `-f` flag (overrides generated auth values)
- VALUES_INLINE appended last (overrides everything)

## setup_helm()

Configures the Helm chart source:

```bash
function setup_helm() {
    local helm_branch=$1

    # Always adds prometheus-community repo (with retry)
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

    if [[ -n "$helm_branch" ]]; then
        # Clone specific branch from GitHub
        git clone -b "$helm_branch" https://github.com/weaviate/weaviate-helm.git /tmp/weaviate-helm
        # Package chart to .tgz for helm install
        helm package -d /tmp/weaviate-helm /tmp/weaviate-helm/weaviate
        TARGET=/tmp/weaviate-helm/weaviate-*.tgz
    else
        # Use published chart from Helm repo
        helm repo add weaviate https://weaviate.github.io/weaviate-helm
        helm repo update --timeout "$HELM_REPO_UPDATE_TIMEOUT"
        TARGET="weaviate/weaviate"
    fi
}
```

## Key Helm Values

### Core

| Flag | Description |
|------|-------------|
| `image.tag` | Weaviate version |
| `image.repo` | Image repository (default: semitechnologies/weaviate) |
| `replicas` | Number of Weaviate replicas |
| `image.registry` | Image registry (set to docker.io for local images) |
| `imagePullPolicy` | Set to Never for local images |

### Auth

| Flag | Description |
|------|-------------|
| `authentication.anonymous_access.enabled` | Anonymous access |
| `authentication.apikey.enabled` | API key auth |
| `authentication.apikey.allowed_keys` | Comma-separated keys |
| `authentication.apikey.users` | Comma-separated users |
| `authentication.oidc.enabled` | OIDC auth |
| `authorization.rbac.enabled` | RBAC |
| `authorization.rbac.root_users` | Root users |
| `authentication.db_users.enabled` | Dynamic users |

### Monitoring

| Flag | Description |
|------|-------------|
| `env.PROMETHEUS_MONITORING_ENABLED` | Enable metrics |
| `env.PROMETHEUS_MONITORING_GROUP` | Group metrics |
| `env.PROMETHEUS_MONITOR_CRITICAL_BUCKETS_ONLY` | Reduce cardinality |

### S3/Backup

| Flag | Description |
|------|-------------|
| `backups.s3.enabled` | Enable S3 backups |
| `backups.s3.envconfig.BACKUP_S3_ENDPOINT` | MinIO endpoint |
| `offload.s3.enabled` | Enable offloading |
| `env.OFFLOAD_S3_BUCKET_AUTO_CREATE` | Auto-create buckets |

## weaviate-helm Compatibility

The `--set` flags must match the weaviate-helm chart values schema. Reference: https://github.com/weaviate/weaviate-helm

When `HELM_BRANCH` is set, a specific branch of weaviate-helm is cloned and used. This is important for:
- Testing unreleased chart features
- Compatibility with older Weaviate versions (e.g., pre-Raft uses older chart versions)
- CI tests that pin specific chart versions

### Chart Version Mapping (from CI)

| Weaviate Version | Chart Branch |
|-----------------|--------------|
| 1.24.x (pre-Raft) | `v16.8.8` |
| 1.25.x (Raft) | `v17.0.0` |
| latest | `main` or published |
