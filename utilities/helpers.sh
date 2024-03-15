
function wait_weaviate() {
  echo "Wait for Weaviate to be ready"
  for _ in {1..120}; do
    if curl -sf -o /dev/null localhost:${WEAVIATE_PORT}; then
      echo "Weaviate is ready"
      break
    fi

    echo "Weaviate is not ready, trying again in 1s"
    sleep 1
  done
}

# This auxiliary function returns the number of voters based on the number of nodes, passing the number of nodes as an argument.
function get_voters() {
    if [[ $1 -ge 10 ]]; then
        echo 7
    elif [[ $1 -ge 7 && $1 -lt 10 ]]; then
        echo 5
    elif [[ $1 -ge 3 && $1 -lt 7 ]]; then
        echo 3
    else
        echo 1
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

        VERSION="v0.0.6"

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
            echo "Unsupported operating system or architecture"
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