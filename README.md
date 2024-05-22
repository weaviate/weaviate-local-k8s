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
- **values-override**: Override values for the Helm chart in YAML string. (Optional, default: '')

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
