#!/bin/bash
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
)

# NOTE: If triggering some of the scripts locally on Mac, you might find an error from the test complaining
# that the injection Docker container can't connect to localhost:8080. This is because the Docker container
# is running in a separate network and can't access the host network. To fix this, you can use the IP address
# of the host machine instead of localhost, using "host.docker.internal". For example:
# client = weaviate.connect_to_local(host="host.docker.internal")
WEAVIATE_PORT=${WEAVIATE_PORT:-8080}
WEAVIATE_GRPC_PORT=${WEAVIATE_GRPC_PORT:-50051}
MODULES=${MODULES:-""}
HELM_BRANCH=${HELM_BRANCH:-""}
PROMETHEUS_PORT=9091
GRAFANA_PORT=3000
TARGET=""
# Array with the images to be used in the local k8s cluster
WEAVIATE_IMAGES=(
    "semitechnologies/weaviate:${WEAVIATE_VERSION}"
    "semitechnologies/contextionary:en0.16.0-v1.2.1"
)

function upgrade_to_raft() {
    echo "upgrade # Upgrading to RAFT"

    # Upload images to cluster if --local-images flag is passed
    if [ "${1:-}" == "--local-images" ]; then
        echo "Uploading local images to the cluster"
        for image in "${WEAVIATE_IMAGES[@]}"; do
            kind load docker-image $image --name weaviate-k8s
        done
    fi

    # This function sets up weaviate-helm and sets the global env var $TARGET
    setup_helm $HELM_BRANCH

    echo "upgrade # Deleting Weaviate StatefulSet"
    kubectl delete sts weaviate -n weaviate

    HELM_VALUES=$(generate_helm_values)

    VALUES_OVERRIDE=""
    # Check if values-override.yaml file exists
    if [ -f "${CURRENT_DIR}/values-override.yaml" ]; then
        VALUES_OVERRIDE="-f ${CURRENT_DIR}/values-override.yaml"
    fi

    echo -e "upgrade # Upgrading weaviate-helm with values: \n\
        TARGET: $TARGET \n\
        HELM_VALUES: $(echo "$HELM_VALUES" | tr -s ' ') \n\
        VALUES_OVERRIDE: $VALUES_OVERRIDE"
    helm upgrade weaviate $TARGET  \
        --namespace weaviate \
        $HELM_VALUES \
        $VALUES_OVERRIDE
   
    # Wait for Weaviate to be up
    kubectl wait sts/weaviate -n weaviate --for jsonpath='{.status.readyReplicas}'=${REPLICAS} --timeout=100s
    port_forward_to_weaviate
    wait_weaviate

    # Check if Weaviate is up
    curl http://localhost:${WEAVIATE_PORT}/v1/nodes
}


function setup() {

    echo "setup # Setting up Weaviate on local k8s"

    # Create Kind config file
    cat <<EOF > /tmp/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: weaviate-k8s
nodes:
- role: control-plane
$(for i in $(seq 1 $WORKERS); do echo "- role: worker"; done)
EOF

    echo "setup # Create local k8s cluster"
    # Create k8s Kind Cluster
    kind create cluster --wait 120s --name weaviate-k8s --config /tmp/kind-config.yaml

    # Upload images to cluster if --local-images flag is passed
    if [ "${1:-}" == "--local-images" ]; then
        echo "Uploading local images to the cluster"
        for image in "${WEAVIATE_IMAGES[@]}"; do
            kind load docker-image $image --name weaviate-k8s
        done
    fi

    # Create namespace
    kubectl create namespace weaviate

    # This function sets up weaviate-helm and sets the global env var $TARGET 
    setup_helm $HELM_BRANCH

    VALUES_OVERRIDE=""
    # Check if values-override.yaml file exists
    if [ -f "${CURRENT_DIR}/values-override.yaml" ]; then
        VALUES_OVERRIDE="-f ${CURRENT_DIR}/values-override.yaml"
    fi

    HELM_VALUES=$(generate_helm_values)

    echo -e "setup # Deploying weaviate-helm with values: \n\
        TARGET: $TARGET \n\
        HELM_VALUES: $(echo "$HELM_VALUES" | tr -s ' ') \n\
        VALUES_OVERRIDE: $VALUES_OVERRIDE"
    # Install Weaviate using Helm
    helm upgrade --install weaviate $TARGET \
    --namespace weaviate \
    $HELM_VALUES \
    $VALUES_OVERRIDE
    #--set debug=true

    # Calculate the timeout value based on the number of replicas
    if [[ $REPLICAS -le 1 ]]; then
        TIMEOUT=90s
    else
        TIMEOUT=$((REPLICAS * 60))s
    fi

    # Increase timeout if MODULES is not empty as the module image might take some time to download
    if [ -n "$MODULES" ]; then
        TIMEOUT=900s
    fi

    # Wait for Weaviate to be up
    kubectl wait sts/weaviate -n weaviate --for jsonpath='{.status.readyReplicas}'=${REPLICAS} --timeout=${TIMEOUT}
    port_forward_to_weaviate
    wait_weaviate

    # Check if Weaviate is up
    curl http://localhost:${WEAVIATE_PORT}/v1/nodes
}

function clean() {
    echo "clean # Cleaning up local k8s cluster..."

    # Kill kubectl port-forward processes running in the background
    pkill -f "kubectl-relay" || true

    # Check if Weaviate release exists
    if helm status weaviate -n weaviate &> /dev/null; then
        # Uninstall Weaviate using Helm
        helm uninstall weaviate -n weaviate
    fi

    # Check if Weaviate namespace exists
    if kubectl get namespace weaviate &> /dev/null; then
        # Delete Weaviate namespace
        kubectl delete namespace weaviate
    fi

    # Check if Kind cluster exists
    if kind get clusters | grep -q "weaviate-k8s"; then
        # Delete Kind cluster
        kind delete cluster --name weaviate-k8s
    fi
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
    LOCAL_IMAGES="--local-images"
fi

# Process command line options
case $1 in
    "setup")
        setup $LOCAL_IMAGES
        ;;
    "upgrade")
        upgrade_to_raft $LOCAL_IMAGES
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
