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

function wait_for_minio() {
    kubectl wait pod/minio -n weaviate --for=condition=Ready --timeout=300s
    echo_green "Minio is ready"
    if [[ $ENABLE_BACKUP == "true" ]]; then
        # Run minio/mc in a single shot to create the bucket
        echo_green "Creating Minio bucket"
        kubectl run minio-mc --image="minio/mc" -n weaviate --restart=Never --command -- /bin/sh -c "
        /usr/bin/mc alias set minio http://minio:9000 aws_access_key aws_secret_key;
        if ! /usr/bin/mc ls minio/weaviate-backups > /dev/null 2>&1; then
            /usr/bin/mc mb minio/weaviate-backups;
            /usr/bin/mc policy set public minio/weaviate-backups;
        else
            echo 'Bucket minio/weaviate-backups already exists.';
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
}

function shutdown_minio() {
    echo_green "Shutting down Minio"
    kubectl delete -f  "$(dirname "$0")/manifests/minio-dev.yaml" || true
}

function wait_weaviate() {
    echo_green "Wait for Weaviate to be ready"
    for _ in {1..120}; do
        if curl -sf -o /dev/null localhost:${WEAVIATE_PORT}; then
            echo_green "Weaviate is ready"
            break
        fi

        echo_yellow "Weaviate is not ready, trying again in 1s"
        sleep 1
    done
}

function wait_for_other_services() {

    # Wait for minio service to be ready if S3 offload or backup is enabled
    if [[ $S3_OFFLOAD == "true" ]] || [[ $ENABLE_BACKUP == "true" ]]; then
        wait_for_minio
    fi

    # Wait for monitoring to be ready if observability is enabled
    if [[ $OBSERVABILITY == "true" ]]; then
        wait_for_monitoring
    fi
}

function wait_cluster_join() {
    node=$1

    echo_green "Wait for node ${node} to join the cluster"
    for _ in {1..120}; do
        if curl -sf localhost:${WEAVIATE_PORT}/v1/nodes | jq ".nodes[] | select(.name == \"${node}\" ) | select (.status == \"HEALTHY\" )" | grep -q $node; then
            echo_green "Node ${node} has joined the cluster"
            break
        fi

        echo_yellow "Node ${node} has not joined the cluster, trying again in 1s"
        sleep 1
    done
}

function is_node_healthy() {
    node=$1
    if curl -sf localhost:${WEAVIATE_PORT}/v1/nodes | jq ".nodes[] | select(.name == \"${node}\" ) | select (.status == \"HEALTHY\" )" | grep -q $node; then
        echo "true"
    else
        echo "false"
    fi
}

function wait_for_all_healthy_nodes() {
    replicas=$1
    echo_green "Wait for all Weaviate $replicas nodes in cluster"
    for _ in {1..120}; do
        healty_nodes=0
        for i in $(seq 0 $((replicas-1))); do
            node="weaviate-$i"
            is_healthy=$(is_node_healthy $node)
            if [ "$is_healthy" == "true" ]; then
                healty_nodes=$((healty_nodes+1))
            else
                echo_yellow "Weaviate node $node is not healthy"
            fi
        done

        if [ "$healty_nodes" == "$replicas" ]; then
            echo_green "All Weaviate $replicas nodes in cluster are healthy"
            break
        fi

        echo_yellow "Not all Weaviate nodes in cluster are healthy, trying again in 2s"
        sleep 2
    done
}

function wait_for_raft_sync() {
    nodes_count=$1
    if [ "$(curl -s -o /dev/null -w "%{http_code}" localhost:${WEAVIATE_PORT}/v1/cluster/statistics)" == "200" ]; then
        echo_green "Wait for Weaviate Raft schema to be in sync"
        for _ in {1..1200}; do
            statistics=$(curl -sf http://localhost:${WEAVIATE_PORT}/v1/cluster/statistics)
            count=$(echo $statistics | jq '.statistics | length')
            synchronized=$(echo $statistics | jq '.synchronized')
            if [ "$count" == "$nodes_count" ] && [ "$synchronized" == "true" ]; then
                echo_green "Weaviate $count nodes out of $nodes_count are synchronized: $synchronized."
                echo_green "Weaviate Raft cluster is in sync"
                break
            fi
            echo_yellow "Weaviate $count nodes out of $nodes_count are synchronized: $synchronized..."
            echo_yellow "Raft schema is out of sync, trying again to query Weaviate $nodes_count nodes cluster in 2s"
            sleep 2
        done
    fi
}

function port_forward_to_weaviate() {
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

    /tmp/kubectl-relay svc/weaviate -n weaviate ${WEAVIATE_PORT}:80 -n weaviate &> /tmp/weaviate_frwd.log &

    /tmp/kubectl-relay svc/weaviate-grpc -n weaviate ${WEAVIATE_GRPC_PORT}:50051 -n weaviate &> /tmp/weaviate_grpc_frwd.log &

    /tmp/kubectl-relay sts/weaviate -n weaviate ${WEAVIATE_METRICS}:2112 &> /tmp/weaviate_metrics_frwd.log &

    if [[ $OBSERVABILITY == "true" ]]; then
        /tmp/kubectl-relay svc/prometheus-grafana -n monitoring ${GRAFANA_PORT}:80 &> /tmp/grafana_frwd.log &

        /tmp/kubectl-relay svc/prometheus-kube-prometheus-prometheus -n monitoring ${PROMETHEUS_PORT}:9090 &> /tmp/prometheus_frwd.log &
    fi
}

function generate_helm_values() {
    local helm_values="--set image.tag=$WEAVIATE_VERSION \
                        --set replicas=$REPLICAS \
                        --set grpcService.enabled=true \
                        --set env.RAFT_BOOTSTRAP_TIMEOUT=3600 \
                        --set env.LOG_LEVEL=info \
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

    if [[ $S3_OFFLOAD == "true" ]]; then
        secrets="--set offload.s3.secrets.AWS_ACCESS_KEY_ID=aws_access_key --set offload.s3.secrets.AWS_SECRET_ACCESS_KEY=aws_secret_key"
        if [[ $ENABLE_BACKUP == "true" ]]; then
            # if backup was already enabled we need to reference that S3 AWS secret.
            secrets="--set offload.s3.envSecrets.AWS_ACCESS_KEY_ID=backup-s3 --set offload.s3.envSecrets.AWS_SECRET_ACCESS_KEY=backup-s3"
        fi
        helm_values="${helm_values} --set offload.s3.enabled=true --set offload.s3.envconfig.OFFLOAD_S3_BUCKET_AUTO_CREATE=true --set offload.s3.envconfig.OFFLOAD_S3_ENDPOINT=http://minio:9000 ${secrets}"
    fi

    if [[ $OBSERVABILITY == "true" ]]; then
        helm_values="${helm_values} --set serviceMonitor.enabled=true"
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
        # Download weaviate-helm repository master branch
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
                "semitechnologies/weaviate:${WEAVIATE_VERSION}"
                "alpine"
    )
    if [[ $MODULES != "" ]]; then
        # Determine the images to be used in the local k8s cluster based on the MODULES variable
        case "$MODULES" in
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
            # Add more cases as needed for other modules
            *)
                echo "Unknown module: $MODULES. No additional images will be used."
                ;;
        esac
    fi
    echo_green "Uploading local images to the cluster"
    for image in "${WEAVIATE_IMAGES[@]}"; do
        check_and_pull_image $image
        kind load docker-image $image --name weaviate-k8s
    done
}