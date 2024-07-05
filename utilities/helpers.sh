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
    kubectl wait pod/minio -n weaviate --for=condition=Ready --timeout=30s
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
}

function generate_helm_values() {
    local helm_values="--set image.tag=$WEAVIATE_VERSION \
                        --set replicas=$REPLICAS \
                        --set grpcService.enabled=true \
                        --set env.RAFT_BOOTSTRAP_TIMEOUT=3600 \
                        --set env.LOG_LEVEL=info \
                        --set env.DISABLE_RECOVERY_ON_PANIC=true \
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
        helm_values="${helm_values} --set offload.s3.enabled=true --set offload.s3.envconfig.OFFLOAD_S3_ENDPOINT=http://minio:9000 --set offload.s3.secrets.AWS_ACCESS_KEY_ID=aws_access_key --set offload.s3.secrets.AWS_SECRET_ACCESS_KEY=aws_secret_key"
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
