# Troubleshooting

Common issues and solutions for local Weaviate clusters.

## Port Conflicts

**Error:** `Port <port> is already in use`

```bash
# Find process using port
lsof -i :8080

# Kill old port forwarding
pkill kubectl-relay

# Or use different ports
WEAVIATE_PORT=8090 WEAVIATE_GRPC_PORT=60061 WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup
```

## Timeout Issues

### Helm Install/Upgrade Timeout

```bash
# Increase timeout
HELM_TIMEOUT="20m" WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup

# Use local images (avoid slow pulls)
docker pull semitechnologies/weaviate:1.28.0
WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup --local-images
```

Recommended: single node 10m, multi-node 15m, with modules 20m, slow network 25-30m.

### Raft Sync Timeout

**Error:** `Timeout reached - Weaviate Raft schema is not in sync`

```bash
# Check sync status
curl -sf localhost:8080/v1/cluster/statistics | jq '{synchronized, count: (.statistics | length)}'

# Check per-pod (EXPOSE_PODS=true)
for port in 8081 8082 8083; do
  echo "Port $port:"; curl -sf localhost:$port/v1/cluster/statistics | jq '{synchronized}' 2>/dev/null || echo "unavailable"
done

# Check logs
kubectl logs -n weaviate weaviate-0 | grep -i raft | tail -20

# Check pod-to-pod connectivity
kubectl exec -n weaviate weaviate-0 -- curl -s http://weaviate-1.weaviate-headless:8080/v1/meta
```

## Image Pull Failures

**Error:** `ImagePullBackOff` or `toomanyrequests`

```bash
# Use local images
docker pull semitechnologies/weaviate:1.28.0
WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup --local-images

# Provide Docker credentials
docker login
DOCKER_CONFIG="/home/user/.docker/config.json" WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup

# Use alternative registry
WEAVIATE_IMAGE_PREFIX="cr.weaviate.io" WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup
```

## Authentication Errors

**Error:** `401 Unauthorized`

```bash
# Check if auth enabled
kubectl get sts weaviate -n weaviate -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AUTHENTICATION_APIKEY_ENABLED")].value}'

# Use correct key
curl -H "Authorization: Bearer admin-key" localhost:8080/v1/meta

# For OIDC, get fresh token
TOKEN=$(bash "$WEAVIATE_LOCAL_K8S_DIR/scripts/get_user_token.sh" -u admin@example.com)
curl -H "Authorization: Bearer $TOKEN" localhost:8080/v1/meta
```

## Pod Issues

### CrashLoopBackOff

```bash
kubectl logs -n weaviate weaviate-0 --previous  # Previous container logs
kubectl describe pod weaviate-0 -n weaviate      # Events and exit codes

# Common: OOMKilled (exit 137) -> increase memory
VALUES_INLINE="--set resources.limits.memory=8Gi" WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup
```

### Pods Stuck in Pending

```bash
kubectl describe pod weaviate-0 -n weaviate  # Check scheduling issues
kubectl top nodes                             # Check resource availability

# Reduce resource requests
VALUES_INLINE="--set resources.requests.memory=1Gi --set resources.requests.cpu=0.5" \
WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup
```

## Common Error Messages

| Error | Cause | Fix |
|-------|-------|-----|
| `context deadline exceeded` | Timeout | Increase `HELM_TIMEOUT`, use `--local-images` |
| `connection refused` | Service not ready | Wait for pods, check port forwarding |
| `no space left on device` | Disk full | `docker system prune -a`, increase PVC |
| `x509: certificate signed by unknown authority` | TLS issue | Use `--local-images` or `DOCKER_CONFIG` |

## Debug Mode

```bash
DEBUG=true WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup
```

## Nuclear Option: Clean Slate

```bash
./local-k8s.sh clean
pkill kubectl-relay
docker system prune -a -f  # Optional, frees space
WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup
```

## Health Check Script

```bash
echo "Pods:"; kubectl get pods -n weaviate
echo "Nodes:"; curl -sf localhost:8080/v1/nodes | jq '.nodes[] | {name, status}'
echo "Raft:"; curl -sf localhost:8080/v1/cluster/statistics | jq '{synchronized, count: (.statistics | length)}'
echo "Version:"; curl -sf localhost:8080/v1/meta | jq -r '.version'
echo "Port forwarding:"; ps aux | grep kubectl-relay | grep -v grep
```

## Getting Help

- **Local K8s Issues**: https://github.com/weaviate/weaviate-local-k8s/issues
- **Weaviate Core Issues**: https://github.com/weaviate/weaviate/issues
- **Community**: https://forum.weaviate.io or Slack
