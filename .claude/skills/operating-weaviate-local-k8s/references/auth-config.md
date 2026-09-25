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

The helper scripts live on the host (in `scripts/` of this repo) and hit Keycloak via the hostname `keycloak.oidc.svc.cluster.local`, which `local-k8s.sh setup` adds to `/etc/hosts` pointing at the port-forwarded Keycloak service. **Always run them from the host, not from inside the Keycloak pod** — the pod does not contain these scripts.

```bash
# Create user (password = username by default)
bash "$WEAVIATE_LOCAL_K8S_DIR/scripts/create_oidc_user.sh" -u admin@example.com

# Create user and assign to group
bash "$WEAVIATE_LOCAL_K8S_DIR/scripts/create_oidc_user.sh" -u admin@example.com -g admins

# Create a global operator (sets weaviate_global_principal=true).
# Only meaningful when NAMESPACES=true is also set on the cluster.
bash "$WEAVIATE_LOCAL_K8S_DIR/scripts/create_oidc_user.sh" -u admin@example.com -G

# Create a namespaced user (sets weaviate_namespace=customer1).
# Only meaningful when NAMESPACES=true is also set on the cluster.
bash "$WEAVIATE_LOCAL_K8S_DIR/scripts/create_oidc_user.sh" -u tenant1@example.com -n customer1
```

`-n` and `-G` are mutually exclusive — a global operator cannot be bound to a namespace. Both flags work by setting Keycloak user attributes that the `demo` client's protocol mappers expose as JWT claims (`weaviate_namespace`, `weaviate_global_principal`). Weaviate reads those claims when `NAMESPACES_ENABLED=true` and `AUTHENTICATION_OIDC_ENABLED=true` are both set; with namespaces disabled, the attributes are simply ignored.

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

- **create_oidc_user.sh** `-u USERNAME [-g GROUP] [-n NAMESPACE | -G]` - Create Keycloak user; `-n` binds to a Weaviate namespace, `-G` marks as global operator (mutually exclusive)
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
