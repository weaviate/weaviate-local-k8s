# Code Review Guidelines

Detailed review checklist and anti-patterns.

## Critical Review Areas

### 1. generate_helm_values() Correctness

Every `--set` flag must match the weaviate-helm chart values schema. Verify against https://github.com/weaviate/weaviate-helm.

```bash
# Correct: matches chart schema
helm_values="${helm_values} --set authentication.apikey.enabled=true"

# Wrong: made-up path
helm_values="${helm_values} --set auth.apikey=true"
```

### 2. Port Conflicts

New services must not collide with existing ports. Check `verify_ports_available()` and the port allocation table:

| Port | Service |
|------|---------|
| 8080+ | Weaviate HTTP (+ per-pod) |
| 50051+ | Weaviate gRPC (+ per-pod) |
| 2112+ | Weaviate metrics (+ per-pod) |
| 6060+ | Weaviate profiler (+ per-pod) |
| 9000 | MinIO |
| 9090 | Keycloak |
| 9091 | Prometheus |
| 3000 | Grafana |

### 3. Auth-Awareness

Any HTTP call to Weaviate must use `curl_with_auth()`, not raw `curl`:

```bash
# Correct
response=$(curl_with_auth "localhost:8080/v1/nodes")

# Wrong - will fail when RBAC is enabled
response=$(curl -sf localhost:8080/v1/nodes)
```

### 4. Feature Dependencies

Validate prerequisites:
- `USAGE_S3=true` requires `ENABLE_RUNTIME_OVERRIDES=true`
- `DASH0=true` requires `DASH0_TOKEN`
- `AUTH_CONFIG` file must exist

### 5. Cleanup in clean()

New services must be cleaned up properly. Check both:
- Service-specific shutdown (e.g., `shutdown_minio`)
- General Kind cluster deletion handles everything else

### 6. action.yml Parity

Every env var must have a matching action input.

## Review Checklist

```
- [ ] Env var has default in local-k8s.sh (VAR=${VAR:-"default"})
- [ ] Helm values generated correctly in generate_helm_values()
- [ ] Feature works with both --local-images and remote images
- [ ] Timeout calculation updated in get_timeout() if adding services
- [ ] Port forwarding added if service needs external access
- [ ] Clean function handles teardown
- [ ] action.yml input added with env mapping
- [ ] CI test added or existing test updated
- [ ] Works with RBAC enabled (auth-aware)
- [ ] Works with EXPOSE_PODS=true and false
- [ ] New HTTP calls use curl_with_auth()
- [ ] HELM_BRANCH path handled (local chart clone vs repo)
```

## Common Anti-Patterns

### 1. Missing --local-images Handling

```bash
# Anti-pattern: new module without local image support
"new-module")
    helm_values="${helm_values} --set modules.new-module.enabled=true"
    # Missing: no case in use_local_images()
    ;;
```

Fix: Add corresponding case in `use_local_images()`.

### 2. Missing Timeout Update

```bash
# Anti-pattern: new service without timeout increase
setup_new_service  # Takes 60s+ to start
# But get_timeout() doesn't account for it
```

Fix: Add to `get_timeout()`:
```bash
if [ "$NEW_SERVICE" == "true" ]; then
    modules_timeout=$((modules_timeout + 100))
fi
```

### 3. Raw curl Instead of curl_with_auth

```bash
# Anti-pattern: breaks when RBAC is enabled
curl -sf localhost:8080/v1/nodes

# Correct
curl_with_auth "localhost:8080/v1/nodes"
```

### 4. Mutually Exclusive Auth Config

```bash
# Anti-pattern: both enabled simultaneously
authorization:
  rbac:
    enabled: true
  admin_list:
    enabled: true  # WRONG: mutually exclusive with rbac
```

### 5. Non-Idempotent Operations

```bash
# Anti-pattern: fails on re-run
kubectl create namespace weaviate  # Fails if exists

# Correct
kubectl create namespace weaviate 2>/dev/null || true
# Or
kubectl get namespace weaviate &>/dev/null || kubectl create namespace weaviate
```

### 6. Missing HELM_BRANCH Support

```bash
# Anti-pattern: only works with released chart
helm_values="${helm_values} --set newChart.value=true"
# But when HELM_BRANCH is set, the chart might not have this value yet
```

Fix: Check chart compatibility or guard with version checks.

### 7. Hardcoded Ports

```bash
# Anti-pattern: ignores user-configured ports
curl localhost:8080/v1/meta  # Should use $WEAVIATE_PORT

# Correct
curl localhost:${WEAVIATE_PORT}/v1/meta
```

## PR Checklist Template

```markdown
## Changes
- [ ] Brief description of changes

## Testing
- [ ] Local testing with `./local-k8s.sh setup`
- [ ] Tested with RBAC enabled
- [ ] Tested with EXPOSE_PODS=true/false
- [ ] CI tests pass

## Checklist
- [ ] Env var default in local-k8s.sh
- [ ] Helm values in generate_helm_values()
- [ ] action.yml input added
- [ ] CI test coverage
- [ ] Skills documentation updated
```
