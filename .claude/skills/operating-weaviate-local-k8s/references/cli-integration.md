# CLI Integration

Generate weaviate-cli connection configs for local clusters.

## Basic Configuration (No Auth)

```bash
mkdir -p ~/.config/weaviate
cat > ~/.config/weaviate/local.json <<EOF
{
  "host": "localhost",
  "http_port": "8080",
  "grpc_port": "50051"
}
EOF

weaviate-cli --config-file ~/.config/weaviate/local.json get nodes --json
```

## With RBAC (Single User)

```json
{
  "host": "localhost",
  "http_port": "8080",
  "grpc_port": "50051",
  "auth": {
    "type": "api_key",
    "api_key": "admin-key"
  }
}
```

## With RBAC (Multiple Users)

Use `"type": "user"` with `--user` flag to switch between users:

```json
{
  "host": "localhost",
  "http_port": "8080",
  "grpc_port": "50051",
  "auth": {
    "type": "user",
    "admin": "admin-key",
    "dev": "dev-key",
    "readonly": "readonly-key"
  }
}
```

```bash
weaviate-cli --config-file config.json --user admin create collection --collection Movies --json
weaviate-cli --config-file config.json --user readonly get collections --json
```

## With OIDC

### Token as API Key

```bash
TOKEN=$(bash "$WEAVIATE_LOCAL_K8S_DIR/scripts/get_user_token.sh" -u admin@example.com)
cat > ~/.config/weaviate/local-oidc.json <<EOF
{
  "host": "localhost",
  "http_port": "8080",
  "grpc_port": "50051",
  "auth": {
    "type": "api_key",
    "api_key": "$TOKEN"
  }
}
EOF
```

### Multiple OIDC Users

```bash
TOKEN_ADMIN=$(bash "$WEAVIATE_LOCAL_K8S_DIR/scripts/get_user_token.sh" admin@example.com)
TOKEN_DEV=$(bash "$WEAVIATE_LOCAL_K8S_DIR/scripts/get_user_token.sh" dev@example.com)

cat > ~/.config/weaviate/local-oidc-multi.json <<EOF
{
  "host": "localhost",
  "http_port": "8080",
  "grpc_port": "50051",
  "auth": {
    "type": "user",
    "admin": "$TOKEN_ADMIN",
    "dev": "$TOKEN_DEV"
  }
}
EOF

weaviate-cli --config-file ~/.config/weaviate/local-oidc-multi.json --user admin get nodes --json
```

Note: OIDC tokens expire. Regenerate and update config periodically.

## Per-Pod Connections

With `EXPOSE_PODS=true`, connect to specific replicas:

```json
{
  "host": "localhost",
  "http_port": "8081",
  "grpc_port": "50052"
}
```

Pod N: HTTP=`8080+(N+1)`, gRPC=`50051+(N+1)`.

## Config Organization

```
~/.config/weaviate/
  local.json              # No auth
  local-rbac.json         # With RBAC
  local-oidc.json         # With OIDC
  local-pod-0.json        # Specific pod
  local-pod-1.json
```
