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

        echo_yellow "Not all Weaviate nodes in cluster are healthy, trying again in 5s"
        sleep 5
    done
}

function wait_for_raft_sync() {
    nodes_count=$1
    if [ "$(curl -s -o /dev/null -w "%{http_code}" localhost:${WEAVIATE_PORT}/v1/cluster/statistics)" == "200" ]; then
        echo_green "Wait for Weaviate Raft schema to be in sync"
        for _ in {1..1200}; do
            sleep 10
            statistics=$(curl -s localhost:8080/v1/cluster/statistics)
            count=$(echo $statistics | jq '.statistics | length')
            synchronized=$(echo $statistics | jq '.synchronized')
            echo "count: $count synchronized: $synchronized nodes_count: $nodes_count"
            if [ "$count" == "$nodes_count" ] && [ "$synchronized" == "true" ]; then
                ip_addresses_ok="ok"
                for i in $(seq 0 $(($nodes_count-1))); do
                    node="weaviate-$i"
                    is_healthy=$(is_node_healthy $node)
                    if [ "$is_healthy" != "true" ]; then
                        ip_addresses_ok="not_ok"
                    else
                        statistics=$(curl -s localhost:8080/v1/cluster/statistics)
                        raft_conf_count=$(echo $statistics | jq ".statistics[].raft.latestConfiguration | length" | grep -c $nodes_count || echo 0)
                        echo "node: $node raft_conf_count: $raft_conf_count nodes_count: $nodes_count ip_addresses_ok:$ip_addresses_ok"
                        if [ "$raft_conf_count" == "$nodes_count" ]; then
                            echo "try to get current IP..."
                            curr_ip=$(kubectl -n weaviate get endpoints weaviate-headless -o json | jq -r ".subsets[].addresses[] | select(.hostname==\"$node\") | .ip" || exit 1)
                            echo "curr_ip: $curr_ip, now try to get actual raft ips"
                            ips_count=$(echo $statistics | jq -r ".statistics[].raft.latestConfiguration | .[] | select(.id==\"$node\") | .address" | grep -c $curr_ip || echo 0)

                            echo "node: $node ips_count: $ips_count nodes_count: $nodes_count"
                            if [ "$ips_count" != "$nodes_count" ]; then
                                echo "node: $node ip_addresses_ok: not ok in ips_count check"
                                ip_addresses_ok="not_ok"
                            fi
                        else
                            echo "node: $node ip_addresses_ok: not ok in else"
                            ip_addresses_ok="not_ok"
                        fi
                    fi
                done

                if [ "$ip_addresses_ok" == "ok" ]; then
                    echo_green "Weaviate Raft cluster is in sync"
                    break
                fi
            fi
            echo_yellow "Raft schema is out of sync, trying again to query Weaviate $nodes_count nodes cluster in 10s"
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
                helm_values="${helm_values} --set modules.${MODULE}.tag=snowflake-snowflake-arctic-embed-xs-onnx"
            fi
        done
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
        TARGET="weaviate/weaviate"
    fi
}
