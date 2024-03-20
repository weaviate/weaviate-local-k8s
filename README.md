## Weaviate Local K8s Action

### Description
This GitHub composite action allows you to deploy Weaviate to a local Kubernetes cluster.

### Inputs
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
  uses: weaviate/weaviate-local-k8s@v1
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

# Upgrade Weaviate to RAFT configuration
./local-k8s.sh upgrade

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

Example, running preview version of Weaviate, using the `raft-configuration` weaviate-helm branch:
```bash
WEAVIATE_VERSION="preview--d58d616" REPLICAS=5 WORKERS=3 HELM_BRANCH="raft-configuration" WEAVIATE_PORT="8081" ./local-k8s.sh setup
```

If you want to override the weaviate-helm values you can create a `values-override.yaml` file in the same directory where the script is located. The values specified in that file will be passed when invoking helm. A `values-override.yaml.example`file is provided for reference, remove the `example` extension and adapt accordingly if you want to override any weaviate-helm values:

```bash
cp values-override.yaml.example values-override.yaml
```

### Invocation

This action is invoked from a GitHub Actions workflow using the uses keyword followed by the action's repository and version. Input values can be provided using the with keyword within the workflow YAML file.

For local execution of the local-k8s.sh script, ensure you have the necessary dependencies installed and then execute the script with one of the supported options: setup, upgrade, or clean.
