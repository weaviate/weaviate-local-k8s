#!/usr/bin/env bash
set -eou pipefail

# Set the current directory in a variable
CURRENT_DIR="$(dirname "$0")"

# Import functions from utilities.sh
source "$CURRENT_DIR/utilities/helpers.sh"

REQUIREMENTS=(
    "kind"
    "helm"
    "kubectl"
    "curl"
    "nohup"
    "jq"
)

# NOTE: If triggering some of the scripts locally on Mac, you might find an error from the test complaining
# that the injection Docker container can't connect to localhost:8080. This is because the Docker container
# is running in a separate network and can't access the host network. To fix this, you can use the IP address
# of the host machine instead of localhost, using "host.docker.internal". For example:
# client = weaviate.connect_to_local(host="host.docker.internal")
WEAVIATE_PORT=${WEAVIATE_PORT:-8080}
WEAVIATE_GRPC_PORT=${WEAVIATE_GRPC_PORT:-50051}
MODULES=${MODULES:-""}
ENABLE_BACKUP=${ENABLE_BACKUP:-"false"}
S3_OFFLOAD=${S3_OFFLOAD:-"false"}
HELM_BRANCH=${HELM_BRANCH:-""}
VALUES_INLINE=${VALUES_INLINE:-""}
DELETE_STS=${DELETE_STS:-"false"}
REPLICAS=${REPLICAS:-1}
OBSERVABILITY=${OBSERVABILITY:-"true"}
PROMETHEUS_PORT=9091
GRAFANA_PORT=3000
TARGET=""
CLUSTERS=${CLUSTERS:-1}


function get_timeout() {
    # Increase timeout if MODULES is not empty as the module image might take some time to download
    # and calculate the timeout value based on the number of replicas
    modules_timeout=0
    if [ -n "$MODULES" ]; then
        modules_timeout=1200
    fi
    echo "$((modules_timeout + (REPLICAS * 90)))s"
}

function upgrade() {
    echo_green "upgrade # Upgrading to Weaviate ${WEAVIATE_VERSION}"

    # Make sure to set the right context
    kubectl config use-context kind-weaviate-k8s

    # Upload images to cluster if --local-images flag is passed
    if [ "${1:-}" == "--local-images" ]; then
        use_local_images
    fi

    if [[ $S3_OFFLOAD == "true" ]] || [[ $ENABLE_BACKUP == "true" ]]; then
        # if the minio pod is not running, start it
        kubectl get pod -n weaviate minio &> /dev/null || startup_minio
    fi

    # This function sets up weaviate-helm and sets the global env var $TARGET
    setup_helm $HELM_BRANCH

    if [ "$DELETE_STS" == "true" ]; then
        echo_yellow "upgrade # Deleting Weaviate StatefulSet"
        kubectl delete sts weaviate -n weaviate
    else
        echo_green "upgrade # Weaviate StatefulSet is not being deleted"
    fi

    HELM_VALUES=$(generate_helm_values)

    VALUES_OVERRIDE=""
    # Check if values-override.yaml file exists
    if [ -f "${CURRENT_DIR}/values-override.yaml" ]; then
        VALUES_OVERRIDE="-f ${CURRENT_DIR}/values-override.yaml"
    fi

    echo_green "upgrade # Upgrading weaviate-helm with values: \n\
        TARGET: $TARGET \n\
        HELM_VALUES: $(echo "$HELM_VALUES" | tr -s ' ') \n\
        VALUES_OVERRIDE: $VALUES_OVERRIDE"
    helm upgrade weaviate $TARGET  \
        --namespace weaviate \
        $HELM_VALUES \
        $VALUES_OVERRIDE

    # Wait for Weaviate to be up
    TIMEOUT=$(get_timeout)
    echo_green "upgrade # Waiting (with timeout=$TIMEOUT) for Weaviate $REPLICAS node cluster to be ready"
    kubectl wait sts/weaviate -n weaviate --for jsonpath='{.status.readyReplicas}'=${REPLICAS} --timeout=${TIMEOUT}
    echo_green "upgrade # Waiting for rollout upgrade to be over"
    kubectl -n weaviate rollout status statefulset weaviate
    port_forward_to_weaviate
    wait_weaviate
    wait_for_other_services

    # Check if Weaviate is up
    wait_for_all_healthy_nodes $REPLICAS
    # Check if Raft schema is in sync
    wait_for_raft_sync $REPLICAS
    echo_green "upgrade # Success"
}


function setup() {
    echo_green "setup # Setting up Weaviate $WEAVIATE_VERSION on local k8s"

    # Create Kind config file
    cat <<EOF > /tmp/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: weaviate-k8s
networking:
  podSubnet: "10.244.0.0/24"
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    controllerManager:
      extraArgs:
        node-cidr-mask-size-ipv4: "28" # Allows only having 16 IPs per node (9 IPs for Weaviate pods)
$([ "${WORKERS:-""}" != "" ] && for i in $(seq 1 $WORKERS); do echo "- role: worker"; done)
EOF

    echo_green "setup # Create local k8s cluster"
    # Create k8s Kind Cluster
    kind create cluster --wait 120s --name weaviate-k8s --config /tmp/kind-config.yaml

    # Upload images to cluster if --local-images flag is passed
    if [ "${1:-}" == "--local-images" ]; then
        use_local_images
    fi

    # Setup monitoring in the weaviate cluster
    if [[ $OBSERVABILITY == "true" ]]; then
        setup_monitoring
    fi

    # Create multiple clusters
    CLUSTERS=$(echo "$CLUSTERS" | tr -cd '[:digit:]')
    echo_green "Creating ${CLUSTERS} Weaviate clusters"
    for ((cluster=1; cluster<=$CLUSTERS; cluster++)); do
        echo_green "Setting up Weaviate-${cluster} cluster"
        # Create namespace
        kubectl create namespace weaviate-$cluster

        if [[ $S3_OFFLOAD == "true" ]] || [[ $ENABLE_BACKUP == "true" ]]; then
            startup_minio $cluster
        fi

        # This function sets up weaviate-helm and sets the global env var $TARGET
        setup_helm $HELM_BRANCH

        VALUES_OVERRIDE=""
        # Check if values-override.yaml file exists
        if [ -f "${CURRENT_DIR}/values-override.yaml" ]; then
            VALUES_OVERRIDE="-f ${CURRENT_DIR}/values-override.yaml"
        fi

        HELM_VALUES=$(generate_helm_values)

        echo_green "setup # Deploying weaviate-helm with values: \n\
            TARGET: $TARGET \n\
            HELM_VALUES: $(echo "$HELM_VALUES" | tr -s ' ') \n\
            VALUES_OVERRIDE: $VALUES_OVERRIDE"
        # Install Weaviate using Helm
        helm upgrade --install weaviate $TARGET \
        --namespace weaviate-$cluster \
        $HELM_VALUES \
        $VALUES_OVERRIDE
        #--set debug=true


        # Wait for Weaviate to be up
        TIMEOUT=$(get_timeout)
        echo_green "setup # Waiting (with timeout=$TIMEOUT) for Weaviate $REPLICAS node cluster to be ready"
        kubectl wait sts/weaviate -n weaviate-$cluster --for jsonpath='{.status.readyReplicas}'=${REPLICAS} --timeout=${TIMEOUT}
        port_forward_to_weaviate $cluster
        wait_weaviate $cluster

        # Check if Weaviate is up
        wait_for_all_healthy_nodes $REPLICAS $cluster
        echo_green "setup # Success"
        echo_green "setup # Weaviate ${cluster} is up and running on http://localhost:$((${WEAVIATE_PORT} + $cluster))"
    done
    if [[ $OBSERVABILITY == "true" ]]; then
        echo_green "setup # Grafana is accessible on http://localhost:$GRAFANA_PORT (admin/admin)"
        echo_green "setup # Prometheus is accessible on http://localhost:$PROMETHEUS_PORT"
    fi
    
}

function clean() {
    echo_green "clean # Cleaning up local k8s cluster..."

    # Kill kubectl port-forward processes running in the background
    pkill -f "kubectl-relay" || true

    # Make sure to set the right context
    kubectl config use-context kind-weaviate-k8s

    # Clean up additional clusters
    for ((cluster=1; cluster<=$CLUSTERS; cluster++)); do
        # Check if Weaviate release exists in the cluster
        if helm status weaviate -n weaviate-$cluster &> /dev/null; then
            # Uninstall Weaviate using Helm in the cluster
            helm uninstall weaviate -n weaviate-$cluster
        fi

        if [[ $S3_OFFLOAD == "true" ]] || [[ $ENABLE_BACKUP == "true" ]]; then
            shutdown_minio $cluster
        fi

        # Check if Weaviate namespace exists in the cluster
        if kubectl get namespace weaviate-$cluster &> /dev/null; then
            # Delete Weaviate namespace in the cluster
            kubectl delete namespace weaviate-$cluster
        fi
    done

    # Check if Kind cluster exists
    if kind get clusters | grep -q "weaviate-k8s"; then
        # Delete Kind cluster
        kind delete cluster --name weaviate-k8s
    fi
    echo_green "clean # Success"
}


# Main script

# Check if any options are passed
if [ $# -eq 0 ]; then
    echo "Usage: $0 <options> <flags>"
    echo "options:"
    echo "         setup"
    echo "         clean"
    echo "         upgrade"
    echo "flags:"
    echo "         --local-images (optional) [Upload local images to the cluster]"
    exit 1
fi

# Check if all requirements are installed
for requirement in "${REQUIREMENTS[@]}"; do
    if ! command -v $requirement &> /dev/null; then
        echo "Please install '$requirement' before running this script"
        echo "    brew install $requirement"
        exit 1
    fi
done

# Add an optional second argument --local-images (defaults to false) which allows uploading the local images to the cluster using
# kind load docker-image <image-name> --name weaviate-k8s
LOCAL_IMAGES=""
if [ $# -ge 2 ] && [ "$2" == "--local-images" ]; then
    echo "Local images enabled"
    LOCAL_IMAGES="--local-images"
fi

# Process command line options
case $1 in
    "setup")
        setup $LOCAL_IMAGES
        ;;
    "upgrade")
        upgrade $LOCAL_IMAGES
        ;;
    "clean")
        clean
        ;;
    *)
        echo "Invalid option: $1. Use 'setup' or 'clean'"
        exit 1
        ;;
esac


# Retrieve Weaviate logs
if [ $? -ne 0 ]; then
    kubectl logs -n weaviate -l app.kubernetes.io/name=weaviate
fi
