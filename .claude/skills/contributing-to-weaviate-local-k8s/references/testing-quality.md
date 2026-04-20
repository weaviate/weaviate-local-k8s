# Testing and Quality

Test coverage map, adding tests, and quality standards.

## CI Test Coverage Map

| Feature | Test Job | Verified |
|---------|----------|----------|
| Basic multi-node | `run-weaviate-local-k8s-basic` | Replicas, workers, version, metrics |
| All parameters | `run-weaviate-local-k8s-all-params` | All features, RBAC, OIDC, modules, backup, monitoring, MCP, env vars, port exposure |
| Failure handling | `run-weaviate-local-k8s-which-fails` | Bad image graceful failure |
| Modules | `run-weaviate-local-k8s-with-module` | text2vec-contextionary, model2vec |
| Raft upgrade | `run-weaviate-local-k8s-raft-upgrade` | 1.24.9 -> 1.25.0 with DELETE_STS |
| Raft downgrade | `run-weaviate-local-k8s-raft-downgrade` | 1.25.0 -> 1.24.9 with DELETE_STS |
| Upgrade to latest | `run-weaviate-local-k8s-upgrade-to-latest` | 1.26.0 -> latest with EXPOSE_PODS |
| Backup | `run-weaviate-local-k8s-backup` | MinIO, backup operations |
| RBAC | `run-weaviate-local-k8s-rbac` | RBAC auth with admin-key/admin-user |
| Expose pods | `run-weaviate-local-k8s-expose-pods` | Per-pod port forwarding, pod restart reconnection |
| OIDC | `run-weaviate-local-k8s-oidc` | Keycloak OIDC, user creation, token auth |
| Port in use | `run-weaviate-local-k8s-port-in-use` | Port availability check fails when port occupied |

## Standard Verification Checks

Every test should verify at minimum:

```bash
# 1. Correct replica count
replicas=$(kubectl get sts weaviate -n weaviate -o=jsonpath="{.spec.replicas}")
[[ "$replicas" -eq $EXPECTED_REPLICAS ]]

# 2. Correct worker count
workers=$(kubectl get nodes --selector=node-role.kubernetes.io/control-plane!= --no-headers | wc -l)
[[ "$workers" -eq $EXPECTED_WORKERS ]]

# 3. Correct version on all nodes
versions=$(curl -s http://127.0.0.1:8080/v1/nodes | jq '.nodes[] | .version' | tr -d '"')
for version in $versions; do
    [[ "$version" == "$EXPECTED_VERSION" ]]
done

# 4. Metrics endpoint accessible
error=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:2112/metrics)
[[ "$error" -eq 200 ]]
```

## Adding a New Test

### Step 1: Define Test Job

```yaml
run-weaviate-local-k8s-new-feature:
  needs: get-latest-weaviate-version
  runs-on: ubuntu-latest
  name: Test new feature
  env:
    WORKERS: '2'
    REPLICAS: '3'
    WEAVIATE_VERSION: ${{ needs.get-latest-weaviate-version.outputs.LATEST_WEAVIATE_VERSION }}
  steps:
    - name: Checkout
      uses: actions/checkout@v2
    - name: Deploy
      uses: ./
      with:
        workers: ${{ env.WORKERS }}
        replicas: ${{ env.REPLICAS }}
        weaviate-version: ${{ env.WEAVIATE_VERSION }}
        new-feature: 'true'
    - name: Verify
      run: |
        set -ex
        # Standard checks + feature-specific checks
```

### Step 2: Add Feature-Specific Verification

```bash
# Example: verify new env var was set
env_value=$(kubectl get sts weaviate -n weaviate \
  -o=jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MY_NEW_FEATURE")].value}')
[[ "$env_value" == "true" ]]
```

### Step 3: Test with Auth (if applicable)

When RBAC is enabled, use `curl -H "Authorization: Bearer admin-key"` for all HTTP requests.

## Quality Standards

### Bash Script Standards

- `set -eou pipefail` at top of scripts
- Use `${VAR:-"default"}` pattern for env vars with defaults
- Use functions for reusable logic
- Use `echo_green/yellow/red` for colored output
- Use `|| true` for idempotent operations

### Testing Standards

- All test jobs should use `set -ex` in verification steps
- Tests should be independent (can run in any order)
- Use `continue-on-error: true` only for expected-failure tests
- Use auth-aware checks when RBAC is enabled
- Verify cleanup works (clean test job)

### Feature Standards

- Every env var must have a default in `local-k8s.sh`
- Every env var must have an action.yml input
- Every feature must have a CI test
- Health checks must use `curl_with_auth()` not raw `curl`
- New services must have startup + wait functions

## Test Debugging

### Local Testing

```bash
# Run the exact same setup as CI
WORKERS=2 REPLICAS=3 WEAVIATE_VERSION="1.28.0" \
RBAC=true ENABLE_BACKUP=true ./local-k8s.sh setup

# Verify manually
kubectl get pods -n weaviate
curl -sf -H "Authorization: Bearer admin-key" localhost:8080/v1/nodes | jq .
```

### CI Failure Debugging

The action automatically dumps on failure:
- Weaviate pod logs
- Node/pod status
- K8s events
- StatefulSet YAML
- kubectl-relay processes

Look for these in the GitHub Actions logs under "Retrieve weaviate logs" step.
