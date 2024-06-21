## Weaviate Local K8s Action

### Description
This GitHub composite action allows you to deploy Weaviate to a local Kubernetes cluster.

### Inputs
- **operation**: The operation to perform. Possible values: setup | upgrade | clean. (Optional, default: 'setup')
- **weaviate-port**: The port number for Weaviate API. Weaviate's load balancer will be exposed on it. (Optional, default: '8080')
- **weaviate-grpc-port**: The gRPC port number for Weaviate. (Optional, default: '50051')
- **workers**: The number of workers in the Kind Kubernetes cluster. (Optional, default: '3')
- **replicas**: The number of replicas for Weaviate. (Optional, default: '3')
- **weaviate-version**: The version of Weaviate to deploy. (Optional, default: 'latest')
- **helm-branch**: The branch of the Helm chart repository to use. If not specified, then the latest published Helm chart for weaviate/weaviate will used. (Optional, default: '')
- **modules**: The vectorizer/modules that will be started up along with Weaviate. Consists on a comma-separated list of modules. The list of supported modules can be found [here](https://weaviate.io/developers/weaviate/modules)
- **delete-sts**: Allows deleting the Weaviate statefulset before perfoming an upgrade operation. Required for the upgrade from non-RAFT (pre-1.25) to RAFT (1.25)
- **enable-backup**: When set to true it configures Weaviate to support S3 backups using MinIO. Refer to the [backup and restore](https://weaviate.io/developers/weaviate/configuration/backups#) documentation for more information.
- **s3-offload**: When set to true it configures Weaviate to support S3 tenant offloading using MinIO. This functionality is only supported in Weaviate 1.26
- **expose-pods**: Allows accessing each of the weaviate pods on a port number (default: false). The port number will start on weaviate-port (default: 8080) +1. This way, weaviate-0 is exposed on 8081, weaviate-1 in 8082, weaviate-2 in 8083, etc...
- **values-override**: Override values for the Helm chart in YAML string. (Optional, default: '')
- **rbac**: When set to true it will create an admin user with admin role and the API key be `admin-key`. (Optional, default: 'false')
- **rbac-config**: File location containing the RBAC configuration in YAML format. (Optional, default: '')
- **debug**: When set to true it will run the script in debug mode (set -x). (Optional, default: 'false')

### Usage
To use this action in your GitHub Actions workflow, you can add the following step:

```yaml
- name: Deploy Weaviate to local Kubernetes
  uses: weaviate/weaviate-local-k8s@v2
  with:
    weaviate-port: '8080'
    weaviate-grpc-port: '50051'
    workers: '3'
    replicas: '3'
    weaviate-version: 'latest'
    modules: 'text2vec-contextionary'
    values-override: |
      resources:
        requests:
          cpu: '100m'
          memory: '100Mi'
        limits:
          cpu: '100m'
          memory: '100Mi'
      storage:
        size: 50Gi
      env:
        ASYNC_INDEXING: true
        PERSISTENCE_LSM_ACCESS_STRATEGY: 'mmap'
        DISABLE_TELEMETRY: 'true'
      backups:
        s3:
          enabled: true
          envconfig:
            BACKUP_S3_ENDPOINT: 'backup-s3:9000'
            BACKUP_S3_BUCKET: 'weaviate-backups'
            BACKUP_S3_USE_SSL: 'false'

```

### Local Execution

You can also execute the local-k8s.sh script locally. Ensure you have the required dependencies installed:

    kind
    helm
    kubectl
    curl
    nohup

Then, you can execute the script with the desired option:

```bash
#Setup Weaviate instance with RBAC enabled (default admin user only)
WEAVIATE_VERSION="1.28.0" RBAC=true REPLICAS=3 ./local-k8s.sh setup

# Setup Weaviate on local Kubernetes
WEAVIATE_VERSION="1.24.4" REPLICAS=3 ./local-k8s.sh setup

# Setup using Docker images locally from your laptop
WORKERS=2 WEAVIATE_VERSION="1.24.8" REPLICAS=3 ./local-k8s.sh setup --local-images

# Upgrade Weaviate to RAFT configuration
WEAVIATE_VERSION="1.25.0" HELM_BRANCH="raft-configuration" REPLICAS=3 ./local-k8s.sh upgrade

# Clean up the local Kubernetes cluster
./local-k8s.sh clean

```

The environment variables that can be passed are:
- **WEAVIATE_PORT**
- **WEAVIATE_GRPC_PORT**
- **WEAVIATE_VERSION**
- **WORKERS**
- **REPLICAS**
- **HELM_BRANCH**
- **MODULES**
- **RBAC**
- **AUTH_CONFIG**

Example, running preview version of Weaviate, using the `raft-configuration` weaviate-helm branch:
```bash
WEAVIATE_VERSION="preview--d58d616" REPLICAS=5 WORKERS=3 HELM_BRANCH="raft-configuration" WEAVIATE_PORT="8081" ./local-k8s.sh setup
```

If you want to override the weaviate-helm values you can create a `values-override.yaml` file in the same directory where the script is located. The values specified in that file will be passed when invoking helm. A `values-override.yaml.example`file is provided for reference, remove the `example` extension and adapt accordingly if you want to override any weaviate-helm values:

```bash
cp values-override.yaml.example values-override.yaml
```

If you need any specific vectorizer, you can set it via the `MODULES` environment variable, for example:

```bash
MODULES="text2vec-contextionary" WEAVIATE_VERSION="1.24.6" REPLICAS=1 WORKERS=1 ./local-k8s.sh setup
```

This will enable the `text2vec-contextionary`in weaviate-helm and deploy the vectorizer under the weaviate namespace. If you want to enable a vectorizer that requires some extra parameters, you can
do it in combination of the `values-override.yaml`file:

```bash
cat <<EOF > values-override.yaml
text2vec-openai:
  apiKey: ${OPENAI_APIKEY}
EOF

MODULES="text2vec-openai" WEAVIATE_VERSION="1.24.6" REPLICAS=1 WORKERS=1 ./local-k8s.sh setup
```

#### Local Images

One of the problems with Kind, compared to Minikube for example, is that every time you create a new cluster it is downloading the images for the services you deploy, even if the image exists locally on your laptop. To solve this problem you have to options, either to build a [local registry](https://kind.sigs.k8s.io/docs/user/local-registry) or upload the images in advance to your cluster nodes via `kind load docker-image $image --name weaviate-k8s`.

The script has an optional flag that can be passed so that weaviate and contextionary images are taken from your list of local Docker images `--local-images`. To make use of it, simply pass that flag when invoking `setup` or `upgrade`:

```bash
WORKERS=2 WEAVIATE_VERSION="1.24.8" REPLICAS=3 ./local-k8s.sh setup --local-images

WORKERS=2 WEAVIATE_VERSION="1.25" REPLICAS=3 ./local-k8s.sh upgrade --local-images
```

Make sure your images are present in your environment, as otherwise the script will fail saying it can't locate those images locally. Simply run `docker pull semitechnologies/weaviate:${WEAVIATE_VERSION}`.

### Invocation

This action is invoked from a GitHub Actions workflow using the uses keyword followed by the action's repository and version. Input values can be provided using the with keyword within the workflow YAML file.

For local execution of the local-k8s.sh script, ensure you have the necessary dependencies installed and then execute the script with one of the supported options: setup, upgrade, or clean.

## Authentication and Authorization

The repository supports configuring authentication and authorization through a YAML configuration file. This file can be passed using the `AUTH_CONFIG` environment variable when running the script locally, or via the `auth-config` input parameter when using the GitHub Action.

The configuration file supports the following authentication methods:

1. **Anonymous Access**: Enable/disable unauthenticated access to Weaviate
   ```yaml
   authentication:
     anonymous_access:
       enabled: true
   ```

2. **API Key Authentication**: Configure API key-based authentication with associated users
   ```yaml
   authentication:
     apikey:
       enabled: true
       allowed_keys:
         - readOnly-plainText-API-Key
         - admin-plainText-API-Key
       users:
         - api-key-user-readOnly
         - api-key-user-admin
   ```

3. **OIDC Authentication**: Enable OpenID Connect authentication
   ```yaml
   authentication:
     oidc:
       enabled: true
       issuer: ''
       username_claim: ''
       groups_claim: ''
       client_id: ''
   ```

For authorization, two methods are supported:

1. **RBAC**: Role-Based Access Control with admin and viewer roles
   ```yaml
   authorization:
     rbac:
       enabled: true
       admins:
         - admin_user1
         - admin_user2
       viewers:
         - viewer_user1
         - readonly_user1
   ```

2. **Admin List**: Simple admin/readonly user list
   ```yaml
   authorization:
     admin_list:
       enabled: true
       users:
         - admin_user1
         - admin_user2
       read_only_users:
         - readonly_user1
         - readonly_user2
   ```

Example usage:

```bash
AUTH_CONFIG="./auth-config.yaml" WEAVIATE_VERSION="1.27.6" REPLICAS=1 WORKERS=1 ./local-k8s.sh setup
```

### RBAC

Role-Based Access Control (RBAC) is integrated into this repository to manage and secure access to Weaviate. To facilitate configuration, a test example is provided in the `rbac.yaml.example` file.

You have two options to configure RBAC:

1. **Enable RBAC with Default Settings:**

   Simply set the `RBAC` environment variable to `true` when running the setup script. This enables RBAC using the default configuration, which creates an admin user with admin role and the API key be `admin-key`.

   ```bash
   RBAC=true WEAVIATE_VERSION="1.28.6" REPLICAS=1 WORKERS=1 ./local-k8s.sh setup
   ```

2. **Use a Custom RBAC Configuration:**

   For a customized RBAC setup, specify the path to your YAML configuration file using the `AUTH_CONFIG` environment variable. This allows you to define specific roles, users, and permissions as needed.

   ```bash
   RBAC=true AUTH_CONFIG="./custom-rbac.yaml" WEAVIATE_VERSION="1.28.2" REPLICAS=4 WORKERS=3 ./local-k8s.sh setup
   ```

   Make sure to create and configure your `custom-rbac.yaml` based on the structure provided in `rbac.yaml.example`.

By leveraging RBAC, you can ensure that access to Weaviate is managed securely and tailored to your specific requirements.

```



