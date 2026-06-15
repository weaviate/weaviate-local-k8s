# Helper functions for deploying Weaviate through the wcs-weaviate-operator
# (https://github.com/weaviate/wcs-weaviate-operator) instead of weaviate-helm.
# Sourced by local-k8s.sh. Active only when DEPLOYMENT_METHOD=operator.
#
# The operator install manifest (dist/install.yaml) ships CRDs, RBAC, the
# controller Deployment and cert-manager Certificate/Issuer resources. Its
# admission webhooks use failurePolicy=Fail, so cert-manager must be running
# before the operator and the Weaviate CR can be applied.

OPERATOR_NAMESPACE="wcs-weaviate-operator-system"
OPERATOR_DEPLOYMENT="wcs-weaviate-operator-controller-manager"
WEAVIATE_CR_FILE="/tmp/weaviate-cr.yaml"
MINIO_SECRET_NAME="minio-credentials"

# Fail fast on configurations the operator cannot express. Everything listed
# here is weaviate-helm specific (chart values, helm-only modules) or
# contradicts how the operator manages the StatefulSet.
function validate_operator_config() {
    local unsupported=""
    if [[ -n "$HELM_BRANCH" ]]; then unsupported="${unsupported} HELM_BRANCH"; fi
    if [[ -n "$VALUES_INLINE" ]]; then unsupported="${unsupported} VALUES_INLINE"; fi
    if [[ -n "$AUTH_CONFIG" ]]; then unsupported="${unsupported} AUTH_CONFIG"; fi
    if [[ "$MCP" == "true" ]]; then unsupported="${unsupported} MCP"; fi
    if [[ "$S3_OFFLOAD" == "true" ]]; then unsupported="${unsupported} S3_OFFLOAD"; fi
    if [[ "$COLLECTION_EXPORT" == "true" ]]; then unsupported="${unsupported} COLLECTION_EXPORT"; fi
    if [[ "$DELETE_STS" == "true" ]]; then unsupported="${unsupported} DELETE_STS"; fi
    # A leftover values-override.yaml (helm-only, often a personal local file)
    # should not block the operator path; it is simply not used.
    if [ -f "${CURRENT_DIR}/values-override.yaml" ]; then
        echo_yellow "values-override.yaml is helm-only and will be IGNORED with DEPLOYMENT_METHOD=operator (use cr-override.yaml instead)"
    fi

    if [[ -n "$unsupported" ]]; then
        echo_red "DEPLOYMENT_METHOD=operator is incompatible with:${unsupported}"
        echo_red "These options are specific to the weaviate-helm deployment method."
        echo_red "Use cr-override.yaml to customize the Weaviate CR instead of helm values."
        exit 1
    fi

    # The operator's validating webhook only accepts 1 (single node) or an
    # odd number >= 3 of replicas (raft quorum). Catch it before creating
    # the Kind cluster so misconfigurations fail in seconds, not minutes.
    if [[ "$REPLICAS" -ne 1 ]] && { [[ "$REPLICAS" -lt 3 ]] || [[ $((REPLICAS % 2)) -eq 0 ]]; }; then
        echo_red "DEPLOYMENT_METHOD=operator requires REPLICAS to be 1 or an odd number >= 3 (raft quorum). Got: $REPLICAS"
        exit 1
    fi

    # Extra tools only required by the operator path
    local operator_requirements=("git" "docker" "yq")
    for requirement in "${operator_requirements[@]}"; do
        if ! command -v "$requirement" &> /dev/null; then
            echo_red "Please install '$requirement' before running with DEPLOYMENT_METHOD=operator"
            exit 1
        fi
    done

    if [[ -n "$MODULES" ]]; then
        echo_yellow "DEPLOYMENT_METHOD=operator: MODULES are passed to the Weaviate CR (spec.modules.extra),"
        echo_yellow "but the operator does not deploy module inference sidecars (contextionary, transformers, ...)."
        echo_yellow "Modules requiring a companion deployment will not be functional."
    fi
}

function setup_cert_manager() {
    echo_green "*** cert-manager ${CERT_MANAGER_VERSION} (required by operator admission webhooks) ***"
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    kubectl wait --for=condition=available \
        deployment/cert-manager deployment/cert-manager-cainjector deployment/cert-manager-webhook \
        -n cert-manager --timeout=240s
}

# Resolves the operator sources and image, loads the image into Kind and
# installs the operator. Source/image resolution:
#   OPERATOR_DIR    -> use an existing local checkout (PR testing from the
#                      wcs-weaviate-operator repo itself)
#   OPERATOR_BRANCH -> clone that branch of weaviate/wcs-weaviate-operator
#   OPERATOR_IMAGE  -> use this controller image instead of building one from
#                      the sources; if present in the local Docker daemon it
#                      is kind-loaded, otherwise the cluster will pull it
function setup_operator() {
    local src_dir
    if [[ -n "$OPERATOR_DIR" ]]; then
        src_dir="$OPERATOR_DIR"
        if [ ! -f "${src_dir}/dist/install.yaml" ]; then
            echo_red "OPERATOR_DIR=${src_dir} does not look like a wcs-weaviate-operator checkout (missing dist/install.yaml)"
            exit 1
        fi
        echo_green "Using local wcs-weaviate-operator checkout: ${src_dir}"
    else
        src_dir="/tmp/wcs-weaviate-operator"
        rm -rf "$src_dir"
        # weaviate/wcs-weaviate-operator is a private repository. For HTTPS
        # clones a token can be supplied via GH_TOKEN/GITHUB_TOKEN; local
        # users can also point OPERATOR_REPO at an SSH remote.
        local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
        echo_green "Cloning wcs-weaviate-operator (branch: ${OPERATOR_BRANCH})"
        local clone_rc=0
        if [[ -n "$token" ]] && [[ "$OPERATOR_REPO" == https://github.com/* ]]; then
            # Authenticate via GIT_ASKPASS so the token never lands on the
            # command line (where 'ps' or shell history could capture it).
            # GIT_ASKPASS is non-interactive: git runs the helper to read the
            # credential, and the helper only echoes an env var, so nothing
            # secret is written to disk either. The 'x-access-token' username is
            # not sensitive. GIT_TERMINAL_PROMPT=0 keeps it fully automated
            # (fail fast instead of hanging on a tty prompt).
            local askpass
            askpass="$(mktemp)"
            printf '#!/bin/sh\nexec echo "$GIT_ASKPASS_TOKEN"\n' > "$askpass"
            chmod +x "$askpass"
            local auth_url="https://x-access-token@github.com/${OPERATOR_REPO#https://github.com/}"
            GIT_ASKPASS_TOKEN="$token" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
                git clone -b "$OPERATOR_BRANCH" --depth 1 "$auth_url" "$src_dir" || clone_rc=$?
            rm -f "$askpass"
        else
            git clone -b "$OPERATOR_BRANCH" --depth 1 "$OPERATOR_REPO" "$src_dir" || clone_rc=$?
        fi
        if [[ "$clone_rc" -ne 0 ]]; then
            echo_red "Could not clone ${OPERATOR_REPO} (branch: ${OPERATOR_BRANCH})."
            echo_red "The repository is private: provide a token via GH_TOKEN/GITHUB_TOKEN,"
            echo_red "set OPERATOR_REPO to an SSH remote, or point OPERATOR_DIR at a local checkout."
            exit 1
        fi
    fi

    local operator_image="$OPERATOR_IMAGE"
    if [[ -z "$operator_image" ]]; then
        operator_image="wcs-weaviate-operator:local"
        echo_green "Building operator image ${operator_image} from ${src_dir}"
        # Use 'docker buildx build' (BuildKit): the operator's .dockerignore
        # uses an exclude-all + '!**/*.go' re-include pattern that the legacy
        # builder resolves incorrectly (the Go sources never reach the build
        # context). '--load' exports the result into the local Docker daemon —
        # with a buildx container driver it would otherwise stay in the build
        # cache and 'kind load' would fail. '--load' is a buildx-only flag, so
        # we invoke buildx explicitly instead of relying on 'docker build'
        # being aliased to buildx (which is not the case on plain Docker/CI).
        docker buildx build --load --build-arg VERSION=local -t "$operator_image" "$src_dir"
        kind load docker-image "$operator_image" --name weaviate-k8s
    elif docker image inspect "$operator_image" &> /dev/null; then
        echo_green "Loading local operator image ${operator_image} into Kind"
        kind load docker-image "$operator_image" --name weaviate-k8s
    else
        echo_yellow "Operator image ${operator_image} not found locally; the cluster will pull it"
    fi

    # Render the install manifest with the resolved controller image. The
    # manifest ships with the kustomize placeholder 'controller:latest'.
    local manifest="/tmp/wcs-weaviate-operator-install.yaml"
    sed "s|image: controller:latest|image: ${operator_image}|" "${src_dir}/dist/install.yaml" > "$manifest"

    # The manifest contains a ServiceMonitor for the controller. Without the
    # prometheus-operator CRDs (OBSERVABILITY=false) applying it would fail.
    if ! kubectl get crd servicemonitors.monitoring.coreos.com &> /dev/null; then
        echo_yellow "ServiceMonitor CRD not present; stripping operator ServiceMonitor from install manifest"
        yq -i 'select(.kind == "ServiceMonitor" | not)' "$manifest"
    fi

    echo_green "*** wcs-weaviate-operator (image: ${operator_image}) ***"
    # Retry: the Certificate/Issuer resources need the cert-manager webhook,
    # which may still be warming up right after setup_cert_manager.
    local applied="false"
    for _ in {1..10}; do
        if kubectl apply --server-side -f "$manifest"; then
            applied="true"
            break
        fi
        echo_yellow "Failed to apply operator manifest (cert-manager webhook warming up?), retrying in 10s..."
        sleep 10
    done
    if [[ "$applied" != "true" ]]; then
        echo_red "Could not install wcs-weaviate-operator"
        exit 1
    fi

    kubectl wait --for=condition=available "deployment/${OPERATOR_DEPLOYMENT}" \
        -n "$OPERATOR_NAMESPACE" --timeout=300s
    echo_green "wcs-weaviate-operator is running"
}

# MinIO credentials consumed by spec.cloudAuth.aws.credentials. Values match
# the static credentials of manifests/minio-dev.yaml.
function create_minio_credentials_secret() {
    kubectl create secret generic "$MINIO_SECRET_NAME" -n weaviate \
        --from-literal=access-key=aws_access_key \
        --from-literal=secret-key=aws_secret_key \
        --dry-run=client -o yaml | kubectl apply -f -
}

function add_minio_cloud_auth_to_cr() {
    yq -i '.spec.cloudAuth.aws.region = "us-east-1" |
           .spec.cloudAuth.aws.endpoint = "minio:9000" |
           .spec.cloudAuth.aws.credentials.accessKeyId = {"name": "'"$MINIO_SECRET_NAME"'", "key": "access-key"} |
           .spec.cloudAuth.aws.credentials.secretAccessKey = {"name": "'"$MINIO_SECRET_NAME"'", "key": "secret-key"}' \
        "$WEAVIATE_CR_FILE"
}

# Translates the script's env vars into a Weaviate CR. The CR is named
# 'weaviate' on purpose: the operator then creates sts/weaviate, svc/weaviate
# and svc/weaviate-grpc — the same resource names the helm chart produces —
# so all health checks and port-forwarding helpers work for both methods.
#
# Notes on auth: the operator unconditionally enables API key authentication
# with a generated admin key (secret weaviate-operator-admin-key). Anonymous
# access is enabled here unless RBAC is requested, mirroring the helm chart
# defaults. get_bearer_token() in helpers.sh knows how to fetch the generated
# key from the secret.
function generate_weaviate_cr() {
    local anonymous_access="true"
    if [[ "$RBAC" == "true" ]]; then
        anonymous_access="false"
    fi

    cat <<EOF > "$WEAVIATE_CR_FILE"
apiVersion: database.weaviate.io/v1alpha1
kind: Weaviate
metadata:
  name: weaviate
  namespace: weaviate
spec:
  version: "${WEAVIATE_VERSION}"
  replicas: ${REPLICAS}
  istioEnabled: false
  debug: ${DEBUG}
  image:
    repository: "${WEAVIATE_IMAGE_PREFIX}/weaviate"
  authentication:
    anonymousAccess: ${anonymous_access}
  podConfig:
    resources:
      requests:
        cpu: 100m
        memory: 300Mi
    storage:
      size: ${WEAVIATE_STORAGE_SIZE}
    extraEnv:
      - name: DISABLE_RECOVERY_ON_PANIC
        value: "true"
  config:
    disableTelemetry: true
    raft:
      bootstrapTimeout: "3600"
EOF

    if [[ "$RBAC" == "true" ]]; then
        yq -i '.spec.authorization.rbac.enabled = true' "$WEAVIATE_CR_FILE"
    fi

    if [[ "$OIDC" == "true" ]]; then
        yq -i '.spec.authentication.oidc = {
                  "enabled": true,
                  "issuer": "http://'"${KEYCLOAK_HOST}"':9090/realms/weaviate",
                  "usernameClaim": "email",
                  "groupsClaim": "groups",
                  "clientId": "demo",
                  "skipClientIdCheck": false
               }' "$WEAVIATE_CR_FILE"
    fi

    if [[ "$DYNAMIC_USERS" == "true" ]]; then
        yq -i '.spec.podConfig.extraEnv += [{"name": "AUTHENTICATION_DB_USERS_ENABLED", "value": "true"}]' "$WEAVIATE_CR_FILE"
    fi

    if [[ "$ENABLE_BACKUP" == "true" ]]; then
        yq -i '.spec.backup.s3 = {"bucket": "weaviate-backups", "useSSL": false}' "$WEAVIATE_CR_FILE"
        add_minio_cloud_auth_to_cr
    fi

    if [[ "$USAGE_S3" == "true" ]]; then
        yq -i '.spec.usage.s3 = {"bucket": "weaviate-usage", "prefix": "billing"} |
               .spec.usage.scrapeInterval = "10s"' "$WEAVIATE_CR_FILE"
        add_minio_cloud_auth_to_cr
    fi

    if [[ -n "$MODULES" ]]; then
        IFS=',' read -ra CR_MODULES <<< "$MODULES"
        for MODULE in "${CR_MODULES[@]}"; do
            yq -i '.spec.modules.extra += ["'"$MODULE"'"]' "$WEAVIATE_CR_FILE"
        done
    fi

    # cr-override.yaml is the operator-mode counterpart of values-override.yaml:
    # a partial Weaviate CR deep-merged on top of the generated one (maps are
    # merged, arrays appended).
    if [ -f "${CURRENT_DIR}/cr-override.yaml" ]; then
        echo_green "Merging cr-override.yaml into the generated Weaviate CR"
        yq eval-all -i 'select(fileIndex == 0) *+ select(fileIndex == 1)' \
            "$WEAVIATE_CR_FILE" "${CURRENT_DIR}/cr-override.yaml"
    fi
}

# Applies the Weaviate CR with retries: right after the operator deployment
# turns available its webhook endpoints may still refuse connections for a
# few seconds, and the CA bundle injection may lag.
function deploy_weaviate_cr() {
    echo_green "Applying Weaviate CR: \n$(cat "$WEAVIATE_CR_FILE")"
    local applied="false"
    for _ in {1..30}; do
        if kubectl apply -f "$WEAVIATE_CR_FILE"; then
            applied="true"
            break
        fi
        echo_yellow "Failed to apply Weaviate CR (operator webhook warming up?), retrying in 5s..."
        sleep 5
    done
    if [[ "$applied" != "true" ]]; then
        echo_red "Could not apply the Weaviate CR"
        log_operator_debug_info
        exit 1
    fi
}

# After an upgrade the operator has to reconcile the CR change into the
# StatefulSet before 'kubectl rollout status' means anything. Wait until the
# StatefulSet pod template references the expected weaviate image.
function wait_for_operator_sts_image() {
    local expected_image="${WEAVIATE_IMAGE_PREFIX}/weaviate:${WEAVIATE_VERSION}"
    echo_green "Waiting for operator to roll StatefulSet to image ${expected_image}"
    for _ in {1..60}; do
        local current_image
        current_image=$(kubectl get sts weaviate -n weaviate -o jsonpath='{.spec.template.spec.containers[?(@.name=="weaviate")].image}' 2>/dev/null || true)
        if [[ "$current_image" == "$expected_image" ]]; then
            echo_green "StatefulSet template updated to ${expected_image}"
            return
        fi
        echo_yellow "StatefulSet image is '${current_image:-<none>}', waiting for operator reconcile..."
        sleep 5
    done
    echo_red "Operator did not update the StatefulSet to ${expected_image} in time"
    log_operator_debug_info
    exit 1
}

function wait_for_weaviate_cr_ready() {
    local timeout=$1
    echo_green "Waiting (timeout=${timeout}) for Weaviate CR to report Ready"
    if ! kubectl wait weaviate/weaviate -n weaviate --for=condition=Ready --timeout="$timeout"; then
        echo_red "Weaviate CR did not become Ready"
        log_operator_debug_info
        exit 1
    fi
}

function log_operator_debug_info() {
    echo_yellow "---------- wcs-weaviate-operator debug dump ----------"
    echo_yellow "[CR] weaviate/weaviate:"
    kubectl get weaviate weaviate -n weaviate -o yaml 2>/dev/null || echo_yellow "Weaviate CR not found"
    echo_yellow "[Operator] deployment + pods:"
    kubectl get deployment,pods -n "$OPERATOR_NAMESPACE" -o wide 2>/dev/null || true
    echo_yellow "[Operator] last logs:"
    kubectl logs -n "$OPERATOR_NAMESPACE" "deployment/${OPERATOR_DEPLOYMENT}" --tail=100 2>/dev/null || true
    echo_yellow "------------------------------------------------------"
}
