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
WEAVIATE_METRICS=${WEAVIATE_METRICS:-2112}
PROFILER_PORT=${PROFILER_PORT:-6060}
EXPOSE_PODS=${EXPOSE_PODS:-"true"}
WEAVIATE_IMAGE_PREFIX=${WEAVIATE_IMAGE_PREFIX:-semitechnologies}
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
KEYCLOAK_PORT=9090
KEYCLOAK_HOST=keycloak.oidc.svc.cluster.local
TARGET=""
RBAC=${RBAC:-"false"}
OIDC=${OIDC:-"false"}
DYNAMIC_USERS=${DYNAMIC_USERS:-"false"}
AUTH_CONFIG=${AUTH_CONFIG:-""}
DEBUG=${DEBUG:-"false"}
DOCKER_CONFIG=${DOCKER_CONFIG:-""}

if [[ $DEBUG == "true" ]]; then
    set -x
fi

function get_timeout() {
    # Increase timeout if MODULES is not empty as the module image might take some time to download
    # and calculate the timeout value based on the number of replicas
    modules_timeout=0
    if [ -n "$MODULES" ]; then
        modules_timeout=$((modules_timeout + 1200))
    fi
    if [ "$ENABLE_BACKUP" == "true" ] || [ "$S3_OFFLOAD" == "true" ]; then
        modules_timeout=$((modules_timeout + 100))
    fi
    if [ "$OBSERVABILITY" == "true" ]; then
        modules_timeout=$((modules_timeout + 100))
    fi

    echo "$((modules_timeout + (REPLICAS * 100)))s"
}

function upgrade() {
    echo_green "upgrade # Upgrading to Weaviate ${WEAVIATE_VERSION}"

    # Make sure to set the right context
    kubectl config use-context kind-weaviate-k8s

    # Upload images to cluster if --local-images flag is passed
    if [ "${1:-}" == "--local-images" ]; then
        use_local_images
        # Make sure that the image.registry doesn't point to cr.weaviate.io, otherwise the local images won't be used
        VALUES_INLINE="$VALUES_INLINE --set imagePullPolicy=Never --set image.registry=docker.io"
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
    # during the upgrade we don't need to wait for other modules to be ready, they should be already running
    TIMEOUT=300s
    echo_green "upgrade # Waiting (with timeout=$TIMEOUT) for Weaviate $REPLICAS node cluster to be ready"
    kubectl wait sts/weaviate -n weaviate --for jsonpath='{.status.readyReplicas}'=${REPLICAS} --timeout=${TIMEOUT}
    echo_green "upgrade # Waiting for rollout upgrade to be over"
    kubectl -n weaviate rollout status statefulset weaviate
    port_forward_to_weaviate $REPLICAS
    if [[ $EXPOSE_PODS == "true" ]]; then
        port_forward_weaviate_pods
    fi
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
    verify_ports_available $REPLICAS
    mount_config=""
    if [ "${DOCKER_CONFIG}" != "" ]; then
        mount_config="  extraMounts:
  - containerPath: /var/lib/kubelet/config.json
    hostPath: ${DOCKER_CONFIG}"
    fi
    # Create Kind config file
    cat <<EOF > /tmp/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: weaviate-k8s
nodes:
- role: control-plane
${mount_config}
$([ "${WORKERS:-""}" != "" ] && for i in $(seq 1 $WORKERS); do echo "- role: worker
${mount_config}"; done)
EOF
    conf=$(cat /tmp/kind-config.yaml)
    echo_green "setup # Mounting Docker config file if provided:\n $conf"
    echo_green "setup # Create local k8s cluster"
    # Create k8s Kind Cluster
    kind create cluster --wait 120s --name weaviate-k8s --config /tmp/kind-config.yaml

    # Upload images to cluster if --local-images flag is passed
    if [ "${1:-}" == "--local-images" ]; then
        use_local_images
        # Make sure that the image.registry doesn't point to cr.weaviate.io, otherwise the local images won't be used
        VALUES_INLINE="$VALUES_INLINE --set imagePullPolicy=Never --set image.registry=docker.io"
    fi

    # Create namespace
    kubectl create namespace weaviate

    if [[ $S3_OFFLOAD == "true" ]] || [[ $ENABLE_BACKUP == "true" ]]; then
        startup_minio
    fi

    if [[ $OIDC == "true" ]]; then
        startup_keycloak
    fi

    # This function sets up weaviate-helm and sets the global env var $TARGET
    setup_helm $HELM_BRANCH

    # Setup monitoring in the weaviate cluster
    if [[ $OBSERVABILITY == "true" ]]; then
        setup_monitoring
    fi

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
    --namespace weaviate \
    $HELM_VALUES \
    $VALUES_OVERRIDE
    #--set debug=true


    # Wait for Weaviate to be up
    TIMEOUT=$(get_timeout)
    for i in {1..40}; do
        if kubectl get sts weaviate -n weaviate -o jsonpath='{.status.readyReplicas}' | grep -q "^${REPLICAS}$"; then
            echo_green "setup # Found readyReplicas status"
            break
        fi
        echo_green "setup # Waiting 20s for readyReplicas status to be available"
        sleep 5
    done
    echo_green "setup # Waiting (with timeout=$TIMEOUT) for Weaviate $REPLICAS node cluster to be ready"
    kubectl wait sts/weaviate -n weaviate --for jsonpath='{.status.readyReplicas}'=${REPLICAS} --timeout=${TIMEOUT}
    port_forward_to_weaviate $REPLICAS
    if [[ $EXPOSE_PODS == "true" ]]; then
        port_forward_weaviate_pods
    fi
    wait_weaviate
    wait_for_other_services

    # Check if Weaviate is up
    wait_for_all_healthy_nodes $REPLICAS
    echo_green "setup # Success"
    echo_green "setup # Weaviate is up and running on http://localhost:$WEAVIATE_PORT"
    if [[ $EXPOSE_PODS == "true" ]]; then
        echo_green "setup # Pod's ports are forwarded to:"
        for i in $(seq 0 $((REPLICAS-1))); do
             echo_green "setup # Weaviate-$i: HTTP=>$((WEAVIATE_PORT+i+1)), GRPC=>$((WEAVIATE_GRPC_PORT+i+1)), METRICS=>$((WEAVIATE_METRICS+i+1)), PROFILER=>$((PROFILER_PORT+i+1))"
        done
    fi
    if [[ $RBAC == "true" ]]; then
        echo_green "setup # RBAC is enabled"
    fi
    auth_enabled=$(is_auth_enabled)
    if [[ "$auth_enabled" == "true" ]]; then
        bearer_token=$(get_bearer_token)
        echo_green "setup # You can now access the Weaviate API with the following API key: $bearer_token"
    fi
    if [[ $OIDC == "true" ]]; then
        echo_green "setup # Keycloak is accessible on http://localhost:9090 (admin/admin)"
    fi
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

    # Check if Weaviate release exists
    if helm status weaviate -n weaviate &> /dev/null; then
        # Uninstall Weaviate using Helm
        helm uninstall weaviate -n weaviate
    fi

    if [[ $S3_OFFLOAD == "true" ]] || [[ $ENABLE_BACKUP == "true" ]]; then
        shutdown_minio
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
    echo_green "clean # Success"
}


# Main script

# Check if any options are passed
if [ $# -eq 0 ]; then
    show_help
    exit 1
fi

# Show help if requested
if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    show_help
    exit 0
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
