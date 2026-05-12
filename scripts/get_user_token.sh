#!/usr/bin/env bash

# Help function
function show_help() {
    echo "Usage: $0 -u USERNAME [-p PASSWORD] [-e EXPIRY]"
    echo
    echo "Get OIDC token for a user from Keycloak"
    echo
    echo "Options:"
    echo "  -u USERNAME   Username to get token for (mandatory)"
    echo "  -p PASSWORD   Password for the user (optional, defaults to username)"
    echo "  -e EXPIRY     Override token expiry: plain seconds or Nm/Nh suffix (e.g. 60m, 2h, 3600)."
    echo "                Updates the demo client's access.token.lifespan in Keycloak before"
    echo "                issuing the token. Omit to use the cluster default (1h)."
    echo "  -h            Show this help message"
    exit 1
}

# Parse expiry string (e.g. "60m", "2h", "3600") into seconds
function parse_expiry_seconds() {
    local raw="$1"
    if [[ "$raw" =~ ^([0-9]+)m$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 60 ))
    elif [[ "$raw" =~ ^([0-9]+)h$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 3600 ))
    elif [[ "$raw" =~ ^[0-9]+$ ]]; then
        echo "$raw"
    else
        echo "Error: Invalid expiry format '$raw'. Use seconds (e.g. 3600), Nm (e.g. 60m), or Nh (e.g. 2h)." >&2
        exit 1
    fi
}

# Parse command line arguments
while getopts "u:p:e:h" opt; do
    case $opt in
        u) username="$OPTARG";;
        p) password="$OPTARG";;
        e) expiry="$OPTARG";;
        h) show_help;;
        \?) echo "Invalid option -$OPTARG" >&2; show_help;;
    esac
done

# Check if username is provided
if [ -z "$username" ]; then
    echo "Error: Username is required"
    show_help
fi

# If password not provided, use username as password
if [ -z "$password" ]; then
    password="$username"
fi

# Only update Keycloak lifespan when -e is explicitly provided
if [ -n "$expiry" ]; then
    expiry_seconds=$(parse_expiry_seconds "$expiry")

    ADMIN_TOKEN=$(curl --fail -s -X POST \
        -d "grant_type=password" \
        -d "client_id=admin-cli" \
        -d "username=admin" \
        -d "password=admin" \
        "http://keycloak.oidc.svc.cluster.local:9090/realms/master/protocol/openid-connect/token" | jq -r .access_token)

    if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
        echo "Error: Failed to get Keycloak admin token" >&2
        exit 1
    fi

    # Client-level lifespan overrides realm; only the client setting matters
    CLIENT_UUID=$(curl --fail -s \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        "http://keycloak.oidc.svc.cluster.local:9090/admin/realms/weaviate/clients?clientId=demo" | jq -r '.[0].id')

    if [ -n "$CLIENT_UUID" ] && [ "$CLIENT_UUID" != "null" ]; then
        curl --fail -s -X PUT \
            -H "Authorization: Bearer $ADMIN_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"attributes\": {\"access.token.lifespan\": \"$expiry_seconds\"}}" \
            "http://keycloak.oidc.svc.cluster.local:9090/admin/realms/weaviate/clients/$CLIENT_UUID" > /dev/null
    fi
fi

# Get user token
TOKEN=$(curl -s -X POST \
    -d "grant_type=password" \
    -d "client_id=demo" \
    -d "username=$username" \
    -d "password=$password" \
    "http://keycloak.oidc.svc.cluster.local:9090/realms/weaviate/protocol/openid-connect/token" | jq -r .access_token)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "Error: Failed to get token for user $username" >&2
    exit 1
fi

echo "$TOKEN"
