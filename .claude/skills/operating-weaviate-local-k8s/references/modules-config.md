# Module Configuration

Module system, custom modules, and image management.

## Overview

Modules extend Weaviate with ML capabilities. Enabled via `MODULES` env var (comma-separated).

- **text2vec-*** - Vector embeddings for semantic search
- **generative-*** - Text generation (RAG, summarization)
- **reranker-*** - Result reranking for improved relevance
- **qna-*** - Question-answering transformations

## Standard Modules

### Text Vectorizers

`text2vec-openai`, `text2vec-cohere`, `text2vec-huggingface`, `text2vec-contextionary`, `text2vec-transformers`, `text2vec-palm`, `text2vec-aws`, `text2vec-gpt4all`

### Generative

`generative-openai`, `generative-cohere`, `generative-anthropic`, `generative-palm`, `generative-aws`, `generative-mistral`

### Rerankers

`reranker-cohere`, `reranker-transformers`, `reranker-voyageai`

### Question Answering

`qna-openai`, `qna-transformers`

## Custom Modules

### text2vec-model2vec

Lightweight model2vec embeddings:

```bash
WEAVIATE_VERSION="1.28.0" MODULES="text2vec-model2vec" ./local-k8s.sh setup
```

Uses `semitechnologies/model2vec-inference` image with tag `minishlab-potion-retrieval-32M`. Handled via generic module path in `generate_helm_values()`.

### text2vec-transformers-model2vec

Ultra-fast embeddings using distilled models, deployed via the text2vec-transformers Helm path:

```bash
WEAVIATE_VERSION="1.28.0" MODULES="text2vec-transformers-model2vec" ./local-k8s.sh setup
```

Uses `semitechnologies/model2vec-inference` image with tag `minishlab-potion-multilingual-128M`. Special handling: overrides the `text2vec-transformers` Helm values (repo + tag) rather than using its own module path.

## Common Combinations

```bash
# RAG
MODULES="text2vec-openai,generative-openai"

# Enhanced Search
MODULES="text2vec-cohere,reranker-cohere"

# Self-Hosted Stack
MODULES="text2vec-transformers,generative-ollama,reranker-transformers"

# Multi-Provider
MODULES="text2vec-openai,text2vec-cohere,generative-openai,generative-anthropic"
```

## Deployment

```bash
WEAVIATE_VERSION="1.28.0" MODULES="text2vec-transformers" HELM_TIMEOUT="20m" ./local-k8s.sh setup
```

Module images are large (1-5GB). Timeout auto-increases by 1200s when MODULES is set.

### Local Images

```bash
docker pull semitechnologies/transformers-inference:baai-bge-small-en-v1.5-onnx
WEAVIATE_VERSION="1.28.0" MODULES="text2vec-transformers" ./local-k8s.sh setup --local-images
```

### Override Image Tags

```bash
MODULES="text2vec-transformers" \
VALUES_INLINE="--set modules.text2vec-transformers.tag=sentence-transformers-all-MiniLM-L6-v2" \
./local-k8s.sh setup
```

### Custom Registry

```bash
WEAVIATE_IMAGE_PREFIX="cr.weaviate.io" MODULES="text2vec-transformers" ./local-k8s.sh setup
```

## Verification

```bash
# Check module pods
kubectl get pods -n weaviate

# Check module services
kubectl get svc -n weaviate | grep module

# Test module connectivity
kubectl exec -n weaviate weaviate-0 -- curl -s http://text2vec-transformers:8080/meta

# Check module logs
kubectl logs -n weaviate <module-pod-name>
```

## Model Selection Trade-offs

| Model | Speed | Quality | Memory | Use Case |
|-------|-------|---------|--------|----------|
| model2vec | Fastest | Lower | Low | High-throughput |
| all-MiniLM-L6-v2 | Fast | Medium | Medium | Balanced |
| bge-small-en-v1.5 | Medium | Good | Medium | General purpose |
| bge-base-en-v1.5 | Slow | Better | High | Quality-focused |
