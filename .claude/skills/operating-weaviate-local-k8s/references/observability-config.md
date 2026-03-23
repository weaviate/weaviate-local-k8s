# Observability Configuration

Prometheus, Grafana, Dash0, and debugging.

## Prometheus and Grafana

### Enable (Default)

```bash
WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup  # OBSERVABILITY=true by default
```

Deploys Prometheus (port 9091), Grafana (port 3000, credentials `admin`/`admin`), ServiceMonitors, and 15+ pre-configured dashboards.

### Disable (Faster Startup)

```bash
WEAVIATE_VERSION="1.28.0" OBSERVABILITY=false ./local-k8s.sh setup
```

Weaviate metrics endpoint (port 2112) still available.

## Grafana Dashboards

15+ dashboards including: Weaviate Overview, Object Store, Vector Index (HNSW), Async Indexing, BM25 Index, Batch Import, GraphQL, gRPC, REST API, Raft Consensus, Replication, Tenant Activity, Go Runtime, System Resources, Network I/O.

Access: http://localhost:3000 -> Dashboards -> Browse -> Weaviate folder.

## Weaviate Metrics

```bash
# Service metrics
curl localhost:2112/metrics

# Per-pod metrics (EXPOSE_PODS=true)
curl localhost:2113/metrics  # weaviate-0
curl localhost:2114/metrics  # weaviate-1
```

### Key Metrics

```promql
# Cluster health
weaviate_node_status
weaviate_raft_leader
weaviate_raft_schema_synced

# Performance
rate(weaviate_requests_total[5m])
weaviate_vector_index_query_duration_seconds
histogram_quantile(0.95, rate(weaviate_request_duration_seconds_bucket[5m]))

# Resources
go_memstats_alloc_bytes
go_goroutines

# Data
weaviate_object_count
weaviate_shard_count
```

## Dash0 Integration

```bash
WEAVIATE_VERSION="1.28.0" DASH0=true DASH0_TOKEN="your-token" \
CLUSTER_NAME="my-cluster" ./local-k8s.sh setup
```

Optional overrides: `DASH0_ENDPOINT`, `DASH0_API_ENDPOINT`.

```bash
# Check Dash0
kubectl get all -n dash0-system
kubectl get dash0monitoring -n weaviate
```

## Profiling

With `EXPOSE_PODS=true`:

```bash
go tool pprof http://localhost:6061/debug/pprof/heap      # Pod 0
go tool pprof http://localhost:6061/debug/pprof/profile?seconds=30  # CPU
go tool pprof http://localhost:6061/debug/pprof/goroutine  # Goroutines
```

## Log Access

```bash
# Single pod
kubectl logs -n weaviate weaviate-0 --tail=100

# All replicas
for i in {0..2}; do echo "=== weaviate-$i ==="; kubectl logs -n weaviate weaviate-$i --tail=20; done

# Filter logs
kubectl logs -n weaviate weaviate-0 | grep -i error
kubectl logs -n weaviate weaviate-0 | grep -i raft
```

## Debug Mode

```bash
DEBUG=true WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup
```

Enables `set -x` showing all executed commands.

```bash
# Weaviate debug logging
VALUES_INLINE="--set env.LOG_LEVEL=debug" WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup
```

## Troubleshooting

```bash
# Check Prometheus targets
curl localhost:9091/api/v1/targets | jq '.data.activeTargets[] | select(.health!="up")'

# Check Grafana health
curl localhost:3000/api/health

# Check port forwarding
ps aux | grep kubectl-relay
lsof -i :9091
lsof -i :3000

# Restart port forwarding
pkill kubectl-relay
WEAVIATE_VERSION="1.28.0" ./local-k8s.sh upgrade
```
