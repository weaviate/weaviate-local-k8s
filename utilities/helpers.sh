function echo_green() {
    green='\033[0;32m'
    nc='\033[0m'
    echo -e "${green}${*}${nc}"
}

function echo_yellow() {
    yellow='\033[0;33m'
    nc='\033[0m'
    echo -e "${yellow}${*}${nc}"
}

function echo_red() {
    red='\033[0;31m'
    nc='\033[0m'
    echo -e "${red}${*}${nc}"
}

function startup_minio() {
    echo_green "Starting up Minio"
    kubectl apply -f "$(dirname "$0")/manifests/minio-dev.yaml"
}

function show_help() {
    cat << EOF
Usage: $0 <command> [flags] [ENV_VARS]

Commands:
    setup     Create and configure a local Kubernetes cluster with Weaviate
    upgrade   Upgrade an existing Weaviate installation
    clean     Remove the local Kubernetes cluster and all resources

Flags:
    --local-images    Upload local Docker images to the cluster instead of pulling from registry

Environment Variables:
  Cluster Configuration:
    WORKERS              Number of worker nodes in the Kind cluster (default: 0)
    REPLICAS            Number of Weaviate replicas to deploy (default: 1)
    WEAVIATE_VERSION    Specific Weaviate version to deploy (required)
    EXPOSE_PODS         Expose the Weaviate pods on the host, for http (starts in 8081), grpc (starts in 50052), metrics (starts in 2113) and profiler (starts in 6061) ports, (default: true)
    DEBUG                Run the script in debug mode (set -x) (default: false)
    DOCKER_CONFIG       Docker configuration file for the Kind cluster. Use after 'docker login' with your config file to allow KInD to access image pull secrets and avoid dockerhub rate limits. Often, this config can be found at /home/<user>/.docker/config.json. The path must NOT include ~.

  Network Configuration:
    WEAVIATE_PORT       HTTP API port (default: 8080)
    WEAVIATE_GRPC_PORT  gRPC API port (default: 50051)
    WEAVIATE_METRICS    Metrics port (default: 2112)

  Feature Flags:
    OBSERVABILITY               Enable Prometheus and Grafana monitoring (default: true)
    RBAC                        Enable Role-Based Access Control (default: false)
    AUTH_CONFIG                 Path to custom authentication and authorization configuration file (optional)
    ENABLE_BACKUP               Enable backup functionality with MinIO (default: false)
    S3_OFFLOAD                  Enable S3 data offloading with MinIO (default: false)
    USAGE_S3                    Enable collecting usage metrics in MinIO (default: false)
    ENABLE_RUNTIME_OVERRIDES    Enable weaviate configuration via runtime overrides(default: false)
  Deployment Options:
    MODULES            Comma-separated list of Weaviate modules to enable (default: "")
                       Available modules: https://weaviate.io/developers/weaviate/model-providers
                       Custom modules:
                         * text2vec-transformers-model2vec: Configures a transformers module which uses
                           a model2vec image to scrifice quality for speed.
    HELM_BRANCH        Specific branch of weaviate-helm to use (default: "")
    VALUES_INLINE      Additional Helm values to pass inline (default: "")
    DELETE_STS         Delete StatefulSet during upgrade (default: false)

Examples:
    # Basic setup with single node
    WEAVIATE_VERSION="1.28.0" ./local-k8s.sh setup

    # Multi-node setup with monitoring disabled
    WORKERS=1 REPLICAS=3 WEAVIATE_VERSION="1.28.0" OBSERVABILITY=false ./local-k8s.sh setup

    # Setup with RBAC enabled
    WEAVIATE_VERSION="1.28.0" RBAC=true ./local-k8s.sh setup

    # Setup with custom authentication and authorization configuration
    WEAVIATE_VERSION="1.27.0" RBAC=true AUTH_CONFIG="./auth-config.yaml" ./local-k8s.sh setup

    # Setup with modules and backup enabled
    WEAVIATE_VERSION="1.28.0" MODULES="text2vec-transformers" ENABLE_BACKUP=true ./local-k8s.sh setup

    # Clean up all resources
    ./local-k8s.sh clean

Notes:
    - When using Mac with Docker, use 'host.docker.internal' instead of 'localhost'
      for container connectivity
    - RBAC default configuration creates a single admin user with 'admin-key'
    - Monitoring (when enabled) provides Grafana (port 3000) and Prometheus (port 9091)
EOF
}

function wait_for_minio() {
    kubectl wait pod/minio -n weaviate --for=condition=Ready --timeout=300s
    echo_green "Minio is ready"
    if [[ $ENABLE_BACKUP == "true" || $USAGE_S3 == "true" ]]; then
        # Run minio/mc in a single shot to create the bucket
        # Check if the minio-mc pod already exists and delete it if necessary
        if kubectl get pod minio-mc -n weaviate &>/dev/null; then
            echo_yellow "Pod minio-mc already exists, skipping creation..."
        else
            echo_green "Creating Minio buckets"
            kubectl run minio-mc --image="minio/mc" -n weaviate --restart=Never --command -- /bin/sh -c "
            /usr/bin/mc alias set minio http://minio:9000 aws_access_key aws_secret_key;
            if ! /usr/bin/mc ls minio/weaviate-backups > /dev/null 2>&1; then
                /usr/bin/mc mb minio/weaviate-backups;
                /usr/bin/mc policy set public minio/weaviate-backups;
            else
                echo 'Bucket minio/weaviate-usage already exists.';
            fi;
            if ! /usr/bin/mc ls minio/weaviate-usage > /dev/null 2>&1; then
                /usr/bin/mc mb minio/weaviate-usage;
                /usr/bin/mc policy set public minio/weaviate-usage;
            else
                echo 'Bucket minio/weaviate-usage already exists.';
            fi;"
            # Wait for the pod/minio-mc to complete
            timeout=100  # Timeout in seconds
            elapsed=0    # Elapsed time counter

            while [[ $(kubectl get pod minio-mc -n weaviate -o jsonpath='{.status.phase}') != "Succeeded" ]]; do
                if [[ $elapsed -ge $timeout ]]; then
                    echo "Timeout of $timeout seconds reached. Exiting..."
                    exit 1
                fi
                sleep 1
                elapsed=$((elapsed + 1))
            done

            echo "Pod minio-mc has completed successfully."
        fi
    fi
}

function shutdown_minio() {
    echo_green "Shutting down Minio"
    kubectl delete -f  "$(dirname "$0")/manifests/minio-dev.yaml" || true
}

function wait_for_other_services() {
    echo "Waiting for other services to be ready..."
    # Wait for minio service to be ready if S3 offload or backup is enabled
    if [[ $need_minio == "true" ]]; then
        wait_for_minio
    fi

    # Wait for keycloak to be ready if OIDC is enabled
    if [[ $OIDC == "true" ]]; then
        wait_for_keycloak
    fi

    # Wait for monitoring to be ready if observability is enabled
    if [[ $OBSERVABILITY == "true" ]]; then
        wait_for_monitoring
    fi
}

function curl_with_auth() {
    local url=$1
    local extra_args=${2:-}  # Optional additional curl arguments

    auth_enabled=$(is_auth_enabled)
    curl_cmd="curl -sf ${extra_args}"

    if [[ "$auth_enabled" == "true" ]]; then
        bearer_token=$(get_bearer_token)
        curl_cmd="$curl_cmd -H 'Authorization: Bearer $bearer_token'"
    fi

    curl_cmd="$curl_cmd $url"
    eval "$curl_cmd"
}

function wait_cluster_join() {
    node=$1

    echo_green "Wait for node ${node} to join the cluster"
    for _ in {1..120}; do
        if curl_with_auth "localhost:${WEAVIATE_PORT}/v1/nodes" | jq ".nodes[] | select(.name == \"${node}\" ) | select (.status == \"HEALTHY\" )" | grep -q $node; then
            echo_green "Node ${node} has joined the cluster"
            break
        fi

        echo_yellow "Node ${node} has not joined the cluster, trying again in 1s"
        sleep 1
    done
}

function is_auth_enabled() {
    env_auth_enabled=$(kubectl get sts weaviate -n weaviate -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="AUTHENTICATION_APIKEY_ENABLED")].value}')
    if [[ "$env_auth_enabled" == "true" ]]; then
        echo "true"
    else
        # Check configmap as fallback
        config=$(kubectl get configmap -n weaviate weaviate-config -o jsonpath='{.data.conf\.yaml}')
        if [[ -n "$config" ]] && [[ $(echo "$config" | yq -r '.authentication.apikey.enabled') == "true" ]]; then
            echo "true"
        else
            echo "false"
        fi
    fi
}

function get_bearer_token() {
    # Check if auth is enabled via env var first (simpler case)

    # if AUTHENTICATION_APIKEY_ALLOWED_KEYS is set, use the first one
    env_bearer_tokens=$(kubectl get sts weaviate -n weaviate -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="AUTHENTICATION_APIKEY_ALLOWED_KEYS")].value}')
    IFS=',' read -r bearer_token _ <<< "$env_bearer_tokens"
    if [[ -n "$bearer_token" ]]; then
        echo "$bearer_token"
        return
    fi


    # Check configmap as fallback
    if kubectl get configmap -n weaviate weaviate-config &>/dev/null; then
        config=$(kubectl get configmap -n weaviate weaviate-config -o jsonpath='{.data.conf\.yaml}')
        if [[ -n "$config" ]]; then
            bearer_token=$(echo "$config" | yq -r '.authentication.apikey.allowed_keys[0]')
            echo "$bearer_token"
            return
        fi
    fi

}

function wait_weaviate() {
    auth_enabled=$(is_auth_enabled)

    echo_green "Wait for Weaviate to be ready"
    for _ in {1..120}; do
        if curl_with_auth "localhost:${WEAVIATE_PORT}" "-o /dev/null"; then
            echo_green "Weaviate is ready"
            return
        fi

        echo_yellow "Weaviate is not ready, trying again in 1s"
        sleep 1
    done
    echo_red "Weaviate is not ready"
    exit 1
}

function is_node_healthy() {
    node=$1
    response=$(curl_with_auth "localhost:${WEAVIATE_PORT}/v1/nodes")
    if echo "$response" | jq ".nodes[] | select(.name == \"${node}\" ) | select (.status == \"HEALTHY\" )" | grep -q "$node"; then
        echo "true"
    else
        echo "false"
    fi
}

function verify_ports_available() {
    replicas=$1
    echo_green "Verifying ports are available for $replicas Weaviate nodes"

    # Check if default ports are available
    if lsof -i -n -P | grep LISTEN | grep -q ":$WEAVIATE_PORT"; then
        echo_red "Port $WEAVIATE_PORT is already in use by another process."
        exit 1
    fi
    if lsof -i -n -P | grep LISTEN | grep -q ":$WEAVIATE_GRPC_PORT"; then
        echo_red "Port $WEAVIATE_GRPC_PORT is already in use by another process."
        exit 1
    fi
    if lsof -i -n -P | grep LISTEN | grep -q ":$WEAVIATE_METRICS"; then
        echo_red "Port $WEAVIATE_METRICS is already in use by another process."
        exit 1
    fi
    if lsof -i -n -P | grep LISTEN | grep -q ":$PROFILER_PORT"; then
        echo_red "Port $PROFILER_PORT is already in use by another process."
        exit 1
    fi

    if [[ "$EXPOSE_PODS" == "true" ]]; then
        # Check if ports are available for each replica
        for i in $(seq 0 $((replicas-1))); do
            # Check Weaviate exposed port
            if lsof -i -n -P | grep LISTEN | grep -q ":$((WEAVIATE_PORT+i+1))"; then
                echo_red "Port $((WEAVIATE_PORT+i+1)) is already in use"
                exit 1
            fi
            # Check Weaviate grpc port
            if lsof -i -n -P | grep LISTEN | grep -q ":$((WEAVIATE_GRPC_PORT+i+1))"; then
                echo_red "Port $((WEAVIATE_GRPC_PORT+i+1)) is already in use"
                exit 1
            fi
            # Check metrics port
            if lsof -i -n -P | grep LISTEN | grep -q ":$((WEAVIATE_METRICS+i+1))"; then
                echo_red "Port $((WEAVIATE_METRICS+i+1)) is already in use"
                exit 1
            fi

            # Check profiler port
            if lsof -i -n -P | grep LISTEN | grep -q ":$((PROFILER_PORT+i+1))"; then
                echo_red "Port $((PROFILER_PORT+i+1)) is already in use"
                exit 1
            fi
        done
    fi

    echo_green "All required ports are available"
}

function wait_for_all_healthy_nodes() {
    replicas=$1
    echo_green "Wait for all Weaviate $replicas nodes in cluster"
    for _ in {1..120}; do
        healthy_nodes=0
        for i in $(seq 0 $((replicas-1))); do
            node="weaviate-$i"
            if [ "$(is_node_healthy "$node")" == "true" ]; then
                healthy_nodes=$((healthy_nodes+1))
            else
                echo_yellow "Weaviate node $node is not healthy"
            fi
        done

        if [ "$healthy_nodes" == "$replicas" ]; then
            echo_green "All Weaviate $replicas nodes in cluster are healthy"
            return
        fi

        echo_yellow "Not all Weaviate nodes in cluster are healthy, trying again in 2s"
        sleep 2
    done
    echo_red "Weaviate $replicas nodes in cluster are not healthy"
    exit 1
}

function is_statistics_synced_for_port() {
    port=$1
    nodes_count=$2
    label=${3:-}

    if curl_with_auth "localhost:${port}/v1/cluster/statistics" "-o /dev/null -w '%{http_code}'" | grep -q "200"; then
        statistics=$(curl_with_auth "localhost:${port}/v1/cluster/statistics")
        count=$(echo "$statistics" | jq '.statistics | length')
        synchronized=$(echo "$statistics" | jq '.synchronized')
        if [ "$count" == "$nodes_count" ] && [ "$synchronized" == "true" ]; then
            return 0
        fi
        if [ -n "$label" ]; then
            echo_yellow "$label reports count=$count synchronized=$synchronized"
        else
            echo_yellow "Weaviate $count nodes out of $nodes_count are synchronized: $synchronized..."
        fi
    else
        if [ -n "$label" ]; then
            echo_yellow "$label endpoint not ready on port ${port}"
        fi
    fi
    return 1
}


function log_raft_sync_debug_info() {
    nodes_count=$1

    echo_yellow "---------- Raft sync debug dump ----------"
    echo_yellow "[Service] /v1/cluster/statistics:"
    if curl_with_auth "localhost:${WEAVIATE_PORT}/v1/cluster/statistics" "-s -o /dev/null -w '%{http_code}'" | grep -q "200"; then
        curl_with_auth "localhost:${WEAVIATE_PORT}/v1/cluster/statistics" | jq '{synchronized: .synchronized, count: (.statistics | length)}' || true
    else
        echo_yellow "Service statistics endpoint not reachable"
    fi

    echo_yellow "[Service] /v1/nodes:"
    if curl_with_auth "localhost:${WEAVIATE_PORT}/v1/nodes" "-s -o /dev/null -w '%{http_code}'" | grep -q "200"; then
        curl_with_auth "localhost:${WEAVIATE_PORT}/v1/nodes" | jq '{nodes: [.nodes[] | {name: .name, status: .status}]}' || true
    else
        echo_yellow "Service nodes endpoint not reachable"
    fi

    echo_yellow "[K8s] Pods state (namespace weaviate):"
    kubectl get pods -n weaviate -o wide || true

    if [[ "$EXPOSE_PODS" == "true" ]]; then
        for i in $(seq 0 $((nodes_count-1))); do
            port=$((WEAVIATE_PORT+i+1))
            echo_yellow "[Node weaviate-$i] /v1/cluster/statistics on port ${port}:"
            # Best-effort: may fail if the node endpoint isn't up yet
            curl_with_auth "localhost:${port}/v1/cluster/statistics" | jq '{synchronized: .synchronized, count: (.statistics | length)}' 2>/dev/null || echo_yellow "weaviate-$i statistics unavailable"
        done
    fi
    echo_yellow "-----------------------------------------"
}


function wait_for_raft_sync() {
    nodes_count=$1
    timeout=$2

    # Convert timeout (e.g., "300s") to seconds
    timeout_seconds=0
    if [[ "$timeout" =~ ^([0-9]+)s$ ]]; then
        timeout_seconds="${BASH_REMATCH[1]}"
    elif [[ "$timeout" =~ ^([0-9]+)$ ]]; then
        timeout_seconds="${BASH_REMATCH[1]}"
    else
        # fallback: default to 300s if parsing fails
        timeout_seconds=300
    fi

    # Check if /v1/cluster/statistics is supported (older versions may not)
    if ! curl_with_auth "localhost:${WEAVIATE_PORT}/v1/cluster/statistics" "-o /dev/null -w '%{http_code}'" | grep -q "200"; then
        echo_yellow "Cluster statistics endpoint not available; skipping Raft sync verification"
        return
    fi

    start_time=$(date +%s)

    if [[ "$EXPOSE_PODS" == "true" ]]; then
        echo_green "Wait for Weaviate Raft schema to be in sync across $nodes_count nodes"
        while true; do
            synced_nodes=0
            for i in $(seq 0 $((nodes_count-1))); do
                port=$((WEAVIATE_PORT+i+1))
                if is_statistics_synced_for_port "$port" "$nodes_count" "Node weaviate-$i"; then
                    synced_nodes=$((synced_nodes+1))
                fi
            done
            if [ "$synced_nodes" == "$nodes_count" ]; then
                echo_green "Weaviate $synced_nodes nodes out of $nodes_count are synchronized."
                echo_green "Weaviate Raft cluster is in sync"
                return
            fi
            now=$(date +%s)
            elapsed=$((now - start_time))
            if [ "$elapsed" -ge "$timeout_seconds" ]; then
                echo_red "Timeout reached ($timeout) - Weaviate Raft schema is not in sync across all nodes"
                log_raft_sync_debug_info "$nodes_count"
                exit 1
            fi
            echo_yellow "Synchronized nodes: $synced_nodes/$nodes_count; retrying in 2s"
            sleep 2
        done
    else
        # Fallback: service port check (may be load-balanced and less strict)
        echo_green "Wait for Weaviate Raft schema to be in sync (service)"
        while true; do
            if is_statistics_synced_for_port "$WEAVIATE_PORT" "$nodes_count"; then
                echo_green "Weaviate $nodes_count nodes are synchronized (reported via service)."
                echo_green "Weaviate Raft cluster is in sync"
                return
            fi
            now=$(date +%s)
            elapsed=$((now - start_time))
            if [ "$elapsed" -ge "$timeout_seconds" ]; then
                echo_red "Timeout reached ($timeout) - Weaviate Raft schema is not in sync"
                log_raft_sync_debug_info "$nodes_count"
                exit 1
            fi
            echo_yellow "Raft schema is out of sync, trying again to query Weaviate $nodes_count nodes cluster in 2s"
            sleep 2
        done
    fi
}

function port_forward_to_weaviate() {
    replicas=$1
    echo_green "Port-forwarding to Weaviate cluster"
    # Install kube-relay tool to perform port-forwarding
    # Check if kubectl-relay binary is available
    if ! command -v kubectl-relay &> /dev/null; then
        # Retrieve the operating system
        OS=$(uname -s)

        # Retrieve the processor architecture
        ARCH=$(uname -m)

        VERSION="v0.0.10"

        # Determine the download URL based on the OS and ARCH
        if [[ $OS == "Darwin" && $ARCH == "x86_64" ]]; then
            OS_ID="darwin"
            ARCH_ID="amd64"
        elif [[ $OS == "Darwin" && $ARCH == "arm64" ]]; then
            OS_ID="darwin"
            ARCH_ID="arm64"
        elif [[ $OS == "Linux" && $ARCH == "x86_64" ]]; then
            OS_ID="linux"
            ARCH_ID="amd64"
        elif [[ $OS == "Linux" && $ARCH == "aarch64" ]]; then
            OS_ID="linux"
            ARCH_ID="arm64"
        else
            echo_red "Unsupported operating system or architecture"
            exit 1
        fi

        KUBE_RELAY_FILENAME="kubectl-relay_${VERSION}_${OS_ID}-${ARCH_ID}.tar.gz"
        # Download the appropriate version
        curl -L "https://github.com/knight42/krelay/releases/download/${VERSION}/${KUBE_RELAY_FILENAME}" -o /tmp/${KUBE_RELAY_FILENAME}

        # Extract the downloaded file
        tar -xzf "/tmp/${KUBE_RELAY_FILENAME}" -C /tmp
    fi

    /tmp/kubectl-relay svc/weaviate -n weaviate ${WEAVIATE_PORT}:80  &> /tmp/weaviate_frwd.log &

    /tmp/kubectl-relay svc/weaviate-grpc -n weaviate ${WEAVIATE_GRPC_PORT}:50051  &> /tmp/weaviate_grpc_frwd.log &

    /tmp/kubectl-relay sts/weaviate -n weaviate ${WEAVIATE_METRICS}:2112 &> /tmp/weaviate_metrics_frwd.log &


    # Port-forward to keycloak if OIDC is enabled
    if [[ $OIDC == "true" ]]; then
        /tmp/kubectl-relay svc/keycloak -n oidc ${KEYCLOAK_PORT}:9090 &> /tmp/keycloak_frwd.log &
    fi

    # Port-forward to prometheus and grafana if observability is enabled
    if [[ $OBSERVABILITY == "true" ]]; then
        /tmp/kubectl-relay svc/prometheus-grafana -n monitoring ${GRAFANA_PORT}:80 &> /tmp/grafana_frwd.log &

        /tmp/kubectl-relay svc/prometheus-kube-prometheus-prometheus -n monitoring ${PROMETHEUS_PORT}:9090 &> /tmp/prometheus_frwd.log &
    fi
    if [[ $USAGE_S3 == "true" ]]; then
       /tmp/kubectl-relay svc/minio -n weaviate ${MINIO_PORT}:9000 &> /tmp/minio_frwd.log &
    fi
}

function port_forward_weaviate_pods() {

    if ! command -v /tmp/kubectl-relay &> /dev/null; then
        echo_red "kubectl-relay is not installed"
        exit 1
    fi

    # Create individual services for each pod
    for i in $(seq 0 $((REPLICAS-1))); do
        kubectl apply -n weaviate -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: weaviate-$i
spec:
  selector:
    statefulset.kubernetes.io/pod-name: weaviate-$i
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  - name: grpc
    port: 50051
    targetPort: 50051
  - name: metrics
    port: 2112
    targetPort: 2112
  - name: profiler
    port: 6060
    targetPort: 6060
EOF
    done

    # Forward through services instead of direct pod references
    for i in $(seq 0 $((REPLICAS-1))); do
        if ! lsof -i -n -P | grep LISTEN | grep kubectl-r | grep ":$((WEAVIATE_PORT+i+1))"; then
            /tmp/kubectl-relay svc/weaviate-$i -n weaviate $((WEAVIATE_PORT+i+1)):8080 &> /tmp/weaviate_frwd_$i.log &
        fi
        if ! lsof -i -n -P | grep LISTEN | grep kubectl-r | grep ":$((WEAVIATE_GRPC_PORT+i+1))"; then
            /tmp/kubectl-relay svc/weaviate-$i -n weaviate $((WEAVIATE_GRPC_PORT+i+1)):50051 &> /tmp/weaviate_grpc_frwd_$i.log &
        fi
        if ! lsof -i -n -P | grep LISTEN | grep kubectl-r | grep ":$((WEAVIATE_METRICS+i+1))"; then
            /tmp/kubectl-relay svc/weaviate-$i -n weaviate $((WEAVIATE_METRICS+i+1)):2112 &> /tmp/weaviate_metrics_frwd_$i.log &
        fi
        if ! lsof -i -n -P | grep LISTEN | grep kubectl-r | grep ":$((PROFILER_PORT+i+1))"; then
            /tmp/kubectl-relay svc/weaviate-$i -n weaviate $((PROFILER_PORT+i+1)):6060 &> /tmp/weaviate_profiler_frwd_$i.log &
        fi
    done
}

function generate_helm_values() {
    local helm_values="--set image.tag=$WEAVIATE_VERSION \
                        --set replicas=$REPLICAS \
                        --set grpcService.enabled=true \
                        --set env.RAFT_BOOTSTRAP_TIMEOUT=3600 \
                        --set env.DISABLE_RECOVERY_ON_PANIC=true \
                        --set env.PROMETHEUS_MONITORING_ENABLED=true \
                        --set env.DISABLE_TELEMETRY=true"

    # Declare MODULES_ARRAY variable
    declare -a MODULES_ARRAY

    # Check if MODULES variable is not empty
    if [[ -n "$MODULES" ]]; then
        # Splitting $MODULES by comma and iterating over each module
        IFS=',' read -ra MODULES_ARRAY <<< "$MODULES"
        for MODULE in "${MODULES_ARRAY[@]}"; do
            if [[ $MODULE == "text2vec-transformers-model2vec" ]]; then
                helm_values="${helm_values} --set modules.text2vec-transformers.enabled=\"true\""
                helm_values="${helm_values} --set modules.text2vec-transformers.repo=semitechnologies/model2vec-inference"
                helm_values="${helm_values} --set modules.text2vec-transformers.tag=minishlab-potion-multilingual-128M"
                continue
            fi
            # Add module string to helm_values
            helm_values="${helm_values} --set modules.${MODULE}.enabled=\"true\""
            if [[ $MODULE == "text2vec-transformers" ]]; then
                helm_values="${helm_values} --set modules.${MODULE}.tag=baai-bge-small-en-v1.5-onnx"
            fi
        done
    fi

    if [[ $ENABLE_BACKUP == "true" ]]; then
        helm_values="${helm_values} --set backups.s3.enabled=true --set backups.s3.envconfig.BACKUP_S3_ENDPOINT=minio:9000 --set backups.s3.envconfig.BACKUP_S3_USE_SSL=false --set backups.s3.secrets.AWS_ACCESS_KEY_ID=aws_access_key --set backups.s3.secrets.AWS_SECRET_ACCESS_KEY=aws_secret_key"
    fi

    if [[ $USAGE_S3 == "true" ]]; then
        helm_values="${helm_values} --set env.AWS_REGION=us-east-1 --set env.AWS_ENDPOINT=minio.weaviate.svc.cluster.local:9000 --set env.USAGE_S3_BUCKET=weaviate-usage --set env.USAGE_SCRAPE_INTERVAL=10s --set USAGE_S3_PREFIX=billing --set usage.s3.enabled=true"
        helm_values="${helm_values} --set runtime_overrides.values.usage_scrape_interval=10s --set runtime_overrides.values.usage_s3_bucket=weaviate-usage --set runtime_overrides.values.usage_s3_prefix=billing"
    fi

    if [[ $S3_OFFLOAD == "true" ]]; then
        secrets="--set offload.s3.secrets.AWS_ACCESS_KEY_ID=aws_access_key --set offload.s3.secrets.AWS_SECRET_ACCESS_KEY=aws_secret_key"
        if [[ $ENABLE_BACKUP == "true" ]]; then
            # if backup was already enabled we need to reference that S3 AWS secret.
            secrets="--set offload.s3.envSecrets.AWS_ACCESS_KEY_ID=backup-s3 --set offload.s3.envSecrets.AWS_SECRET_ACCESS_KEY=backup-s3"
        fi
        helm_values="${helm_values} --set offload.s3.enabled=true --set offload.s3.envconfig.OFFLOAD_S3_BUCKET_AUTO_CREATE=true --set offload.s3.envconfig.OFFLOAD_S3_ENDPOINT=http://minio:9000 ${secrets}"
    fi

    if [[ $ENABLE_RUNTIME_OVERRIDES == "true" ]]; then
       helm_values="${helm_values} --set runtime_overrides.enabled=true --set runtime_overrides.load_interval=30s --set runtime_overrides.path=${RUNTIME_OVERRIDES_PATH}"
    fi

    if [[ $OBSERVABILITY == "true" ]]; then
        # Add extra metrics monitoring options
        helm_values="${helm_values} --set serviceMonitor.enabled=true \
                            --set env.PROMETHEUS_MONITORING_GROUP=true \
                            --set env.PROMETHEUS_MONITOR_CRITICAL_BUCKETS_ONLY=true"
    fi

    if [[ $DYNAMIC_USERS == "true" ]]; then
        helm_values="${helm_values} --set authentication.db_users.enabled=true"
    fi

    # RBAC configuration.
    # If RBAC is enabled, always enable RBAC in environment
    # also an AUTH_CONFIG can be provided to override the default authentication and authorization configuration.
    if [[ $RBAC == "true" ]]; then
        # Always enable RBAC in environment
        helm_values="${helm_values} --set authorization.rbac.enabled=true"


        if [[ $AUTH_CONFIG == "" ]]; then
            # Use default RBAC configuration
            helm_values="${helm_values} \
                --set authentication.anonymous_access.enabled=false \
                --set authentication.apikey.enabled=true \
                --set authentication.apikey.allowed_keys={admin-key} \
                --set authentication.apikey.users={admin-user} \
                --set authorization.rbac.root_users={admin-user} \
                --set authorization.admin_list.enabled=false"
        fi
    fi

    # OIDC configuration
    # If OIDC is enabled, enable OIDC in environment
    # also an AUTH_CONFIG can be provided to override the default authentication and authorization configuration.
    if [[ $OIDC == "true" ]]; then
        # Enable OIDC in environment
        helm_values="${helm_values} --set authentication.oidc.enabled=true"

        if [[ $AUTH_CONFIG == "" ]]; then
            # Use default OIDC configuration
            helm_values="${helm_values} \
                --set authentication.oidc.issuer=http://${KEYCLOAK_HOST}:9090/realms/weaviate \
                --set authentication.oidc.username_claim=email \
                --set authentication.oidc.groups_claim=groups \
                --set authentication.oidc.client_id=demo \
                --set authentication.oidc.skip_client_id_check=false"
        fi
    fi

    # Check if AUTH_CONFIG is provided
    if [[ $AUTH_CONFIG != "" ]]; then
        if [[ ! -f "$AUTH_CONFIG" ]]; then
            echo_red "Auth config file not found at $AUTH_CONFIG"
            exit 1
        fi

        # Pass the RBAC config file directly to helm
        helm_values="${helm_values} -f $AUTH_CONFIG"
    fi

    # Check if VALUES_INLINE variable is not empty
    if [ "$VALUES_INLINE" != "" ]; then
        helm_values="$helm_values $VALUES_INLINE"
    fi

    echo "$helm_values"
}

function setup_helm () {
    if [ $# -eq 0 ]; then
        HELM_BRANCH=""
    else
        HELM_BRANCH=$1
    fi

    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    if [ -n "${HELM_BRANCH:-}" ]; then
        WEAVIATE_HELM_DIR="/tmp/weaviate-helm"
        # Delete $WEAVIATE_HELM_DIR if it already exists
        if [ -d "$WEAVIATE_HELM_DIR" ]; then
            rm -rf "$WEAVIATE_HELM_DIR"
        fi
        # Download weaviate-helm repository with branch
        git clone -b $HELM_BRANCH https://github.com/weaviate/weaviate-helm.git $WEAVIATE_HELM_DIR
        # Package Weaviate Helm chart
        helm package -d ${WEAVIATE_HELM_DIR} ${WEAVIATE_HELM_DIR}/weaviate
        TARGET=${WEAVIATE_HELM_DIR}/weaviate-*.tgz
    else
        helm repo add weaviate https://weaviate.github.io/weaviate-helm
        helm repo update
        TARGET="weaviate/weaviate"
    fi

}

function setup_monitoring () {

    echo_green "Setting up monitoring"

    echo_green "*** Metrics API ***"
    # Start up metrics api
    kubectl apply -f "$(dirname "$0")/manifests/metrics-server.yaml"

    # Create monitoring namespace
    kubectl create namespace monitoring

    echo_green "*** Prometheus Stack ***"
    # Install kube-prometheus-stack
    helm install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring \
      -f "$(dirname "$0")/helm/kube-prometheus-stack.yaml"

    echo_green "*** Grafana Renderer ***"
    # Deploy grafana-renderer
    #https://grafana.com/grafana/plugins/grafana-image-renderer/
    kubectl apply -f "$(dirname "$0")/manifests/grafana-renderer.yaml"

    echo_green "*** Load Grafana Dashboards ***"
    for file in $(dirname "$0")/manifests/grafana-dashboards/*.yaml
    do
        kubectl apply -f $file
    done
}

function wait_for_monitoring () {

    # Wait for prometheus-grafana deploymnet to be ready
    kubectl wait --for=condition=available deployment/prometheus-grafana -n monitoring --timeout=120s
    echo_green "Prometheus Grafana is ready"

    kubectl wait pod -n monitoring -l app=grafana-renderer --for=condition=Ready --timeout=240s
    echo_green "Grafana Renderer is ready"
}

function startup_keycloak() {
    echo_green "Starting up Keycloak"

    # Create oidc namespace
    kubectl create namespace oidc

    # Create keycloak realm configmap
    kubectl create configmap keycloak-realm -n oidc --from-file=weaviate-realm.json="$(dirname "$0")/manifests/keycloak-weaviate-realm.json"

    # Deploy keycloak
    kubectl apply -f "$(dirname "$0")/manifests/keycloak.yaml"

    # Check if the keycloak host is already in /etc/hosts
    if ! grep -q "${KEYCLOAK_HOST}" /etc/hosts; then
        # Add keycloak host to /etc/hosts if the current user has sudo privileges
        if sudo -n true 2>/dev/null; then
            echo_green "Adding keycloak host to /etc/hosts [Requires sudo]"
            sudo sh -c "echo '127.0.0.1 ${KEYCLOAK_HOST}' >> /etc/hosts"
        else
            echo_red "Current user does not have sudo privileges. Please add the keycloak host to /etc/hosts manually."
            echo_red "You can add the following line to /etc/hosts:"
            echo_red "127.0.0.1 ${KEYCLOAK_HOST}"
        fi
    fi
}

function wait_for_keycloak() {
    kubectl wait --for=condition=available deployment/keycloak -n oidc --timeout=120s
    echo_green "Keycloak is ready"
}

# Function to check if an image exists locally, and if not, pull it
function check_and_pull_image() {
    local image=$1
    if ! docker image inspect "$image" > /dev/null 2>&1; then
        echo "Image $image not found locally. Pulling..."
        docker pull "$image"
    else
        echo "Image $image is already present locally."
    fi
}

# Function to upload local images to the local k8s cluster
function use_local_images() {

    WEAVIATE_IMAGES=(
                "${WEAVIATE_IMAGE_PREFIX}/weaviate:${WEAVIATE_VERSION}"
                "alpine:3.20"
    )
    if [[ $MODULES != "" ]]; then
        # Splitting $MODULES by comma and iterating over each module
        IFS=',' read -ra MODULES_ARRAY <<< "$MODULES"
        for MODULE in "${MODULES_ARRAY[@]}"; do
            # Add module images to WEAVIATE_IMAGES array
            case "$MODULE" in
                "text2vec-transformers")
                    WEAVIATE_IMAGES+=(
                        "semitechnologies/transformers-inference:baai-bge-small-en-v1.5-onnx"
                    )
                    ;;
                "text2vec-contextionary")
                    WEAVIATE_IMAGES+=(
                        "semitechnologies/contextionary:en0.16.0-v1.2.1"
                    )
                    ;;
                "text2vec-model2vec")
                    WEAVIATE_IMAGES+=(
                        "semitechnologies/model2vec-inference:minishlab-potion-retrieval-32M"
                    )
                    ;;
                "text2vec-transformers-model2vec")
                    WEAVIATE_IMAGES+=(
                        "semitechnologies/model2vec-inference:minishlab-potion-multilingual-128M"
                    )
                    ;;
                # Add more cases as needed for other modules
                *)
                    echo "Unknown module: $MODULE. No additional images will be used."
                    ;;
            esac
        done
    fi
    if [[ $need_minio == "true" ]]; then
       WEAVIATE_IMAGES+=(
            "minio/minio:latest"
            "minio/mc:latest"
       )
    fi
    if [ "$OBSERVABILITY" == "true" ]; then
        WEAVIATE_IMAGES+=(
            "grafana/grafana-image-renderer:latest"
        )
    fi
    echo_green "Uploading local images to the cluster"
    for image in "${WEAVIATE_IMAGES[@]}"; do
        check_and_pull_image $image
        kind load docker-image $image --name weaviate-k8s
    done
}
