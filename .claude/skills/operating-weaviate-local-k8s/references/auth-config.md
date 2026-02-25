# Authentication Configuration

RBAC, OIDC, custom AUTH_CONFIG, and dynamic users.

## RBAC (Role-Based Access Control)

### Default Setup

```bash
WEAVIATE_VERSION="1.28.0" RBAC=true ./local-k8s.sh setup
```

Default: user=`admin-user`, key=`admin-key` (root). Anonymous access disabled.

Test: `curl -H "Authorization: Bearer admin-key" localhost:8080/v1/meta`

### Multiple API Keys

Create custom auth config:

```yaml
# custom-rbac.yaml
authentication:
  anonymous_access:
    enabled: false
  apikey:
    enabled: true
    allowed_keys:
      - admin-key
      - user-key
      - readonly-key
    users:
      - admin-user
      - regular-user
      - readonly-user
authorization:
  rbac:
    enabled: true
    root_users:
      - admin-user
  admin_list:
    enabled: false  # Must be false when RBAC is enabled
```

Deploy: `WEAVIATE_VERSION="1.28.0" RBAC=true AUTH_CONFIG="custom-rbac.yaml" ./local-k8s.sh setup`

**Important:** `rbac` and `admin_list` are mutually exclusive. Only one can be enabled.

## OIDC (OpenID Connect)

### Default Setup

```bash
WEAVIATE_VERSION="1.28.0" OIDC=true RBAC=true ./local-k8s.sh setup
```

Deploys Keycloak (port 9090), realm `weaviate`, client `demo`, admin credentials `admin`/`admin`.

### Create OIDC Users

```bash
# Create user (password = username by default)
kubectl exec -n oidc deployment/keycloak -- \
  bash /scripts/create_oidc_user.sh -u admin@example.com

# Create user and assign to group
kubectl exec -n oidc deployment/keycloak -- \
  bash /scripts/create_oidc_user.sh -u admin@example.com -g admins
```

### Get OIDC Token

```bash
TOKEN=$(bash "$WEAVIATE_LOCAL_K8S_DIR/scripts/get_user_token.sh" -u admin@example.com)
curl -H "Authorization: Bearer $TOKEN" localhost:8080/v1/meta
```

Manual token retrieval:
```bash
TOKEN=$(curl -s -X POST \
  -d "grant_type=password" -d "client_id=demo" \
  -d "username=testuser@example.com" -d "password=password123" \
  "http://localhost:9090/realms/weaviate/protocol/openid-connect/token" | jq -r .access_token)
```

## Combined APIKEY + OIDC

```yaml
# combined-auth.yaml
authentication:
  anonymous_access:
    enabled: false
  apikey:
    enabled: true
    allowed_keys:
      - admin-key
    users:
      - admin-user
  oidc:
    enabled: true
    issuer: "http://keycloak.oidc.svc.cluster.local:9090/realms/weaviate"
    username_claim: "email"
    groups_claim: "groups"
    client_id: "demo"
authorization:
  rbac:
    enabled: true
    root_users:
      - admin-user
      - admin@example.com
```

Deploy: `WEAVIATE_VERSION="1.28.0" OIDC=true RBAC=true AUTH_CONFIG="combined-auth.yaml" ./local-k8s.sh setup`

## Dynamic Users

```bash
WEAVIATE_VERSION="1.28.0" RBAC=true DYNAMIC_USERS=true ./local-k8s.sh setup
```

Enables runtime user management stored in Weaviate database. Users can be created/deleted/updated via API without restart.

## Helper Scripts

Located in `$WEAVIATE_LOCAL_K8S_DIR/scripts/`:

- **create_oidc_user.sh** `-u USERNAME [-g GROUP]` - Create Keycloak user
- **get_user_token.sh** `-u USERNAME [-p PASSWORD]` - Get OIDC bearer token
- **create_oidc_group.sh** `-g GROUPNAME` - Create Keycloak group

## Troubleshooting Auth

```bash
# Check if auth enabled
kubectl get sts weaviate -n weaviate -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AUTHENTICATION_APIKEY_ENABLED")].value}'

# Check allowed keys
kubectl get sts weaviate -n weaviate -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AUTHENTICATION_APIKEY_ALLOWED_KEYS")].value}'

# Check Keycloak
kubectl get pods -n oidc
curl http://localhost:9090/realms/weaviate/.well-known/openid-configuration

# Decode OIDC token
echo $TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .
```
