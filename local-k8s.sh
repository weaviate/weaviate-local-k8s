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
PROMETHEUS_PORT=9091
GRAFANA_PORT=3000


function upgrade_to_raft() {
    echo "upgrade # Upgrading to RAFT"
    rm -rf "/tmp/weaviate-helm"
    git clone -b raft-configuration https://github.com/weaviate/weaviate-helm.git "/tmp/weaviate-helm"
    # Package Weaviate Helm chart
    helm package -d /tmp/weaviate-helm /tmp/weaviate-helm/weaviate
    helm upgrade weaviate /tmp/weaviate-helm/weaviate-*.tgz  \
        --namespace weaviate \
        --set image.tag="preview-raft-add-initial-migration-from-non-raft-to-raft-based-representation-c242ac4" \
        --set replicas=$REPLICAS \
        --set grpcService.enabled=true \
        --set env.RAFT_BOOTSTRAP_EXPECT=$(get_voters $REPLICAS)

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

    # Create namespace
    kubectl create namespace weaviate

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

    VALUES_OVERRIDE=""
    # Check if values-override.yaml file exists
    if [ -f "${CURRENT_DIR}/values-override.yaml" ]; then
        VALUES_OVERRIDE="-f ${CURRENT_DIR}/values-override.yaml"
    fi

    # Install Weaviate using Helm
    helm upgrade --install weaviate $TARGET \
    --namespace weaviate \
    --set image.tag=$WEAVIATE_VERSION \
    --set replicas=$REPLICAS \
    --set grpcService.enabled=true \
    --set env.RAFT_BOOTSTRAP_EXPECT=$(get_voters $REPLICAS) \
    --set env.LOG_LEVEL="debug" \
    --set env.DISABLE_TELEMETRY="true" \
    $VALUES_OVERRIDE
    #--set debug=true

    # Calculate the timeout value based on the number of replicas
    if [[ $REPLICAS -le 1 ]]; then
        TIMEOUT=90s
    else
        TIMEOUT=$((REPLICAS * 60))s
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
    echo "Usage: $0 <options>"
    echo "options:"
    echo "         setup"
    echo "         clean"
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

# Process command line options
case $1 in
    "setup")
        setup
        ;;
    "upgrade")
        upgrade_to_raft
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
