#!/usr/bin/env bash

# Help function
function show_help() {
    echo "Usage: $0 -u USERNAME [-g GROUP] [-n NAMESPACE | -G]"
    echo
    echo "Create a user in Keycloak OIDC system"
    echo
    echo "Options:"
    echo "  -u USERNAME    Username to create (mandatory)"
    echo "  -g GROUP       Group to assign user to (optional)"
    echo "  -n NAMESPACE   Bind user to a Weaviate namespace via the"
    echo "                 'weaviate_namespace' user attribute (optional)"
    echo "  -G             Mark user as a Weaviate global operator via the"
    echo "                 'weaviate_global_principal' user attribute (optional)"
    echo "  -h             Show this help message"
    echo
    echo "Notes:"
    echo "  -n and -G are mutually exclusive: a global operator cannot be"
    echo "  bound to a namespace. Use neither for a plain authenticated user."
    exit 1
}

# Parse command line arguments
global_principal="false"
while getopts "u:g:n:Gh" opt; do
    case $opt in
        u) username="$OPTARG";;
        g) group="$OPTARG";;
        n) namespace="$OPTARG";;
        G) global_principal="true";;
        h) show_help;;
        \?) echo "Invalid option -$OPTARG" >&2; show_help;;
    esac
done

# Check if username is provided
if [ -z "$username" ]; then
    echo "Error: Username is required"
    show_help
fi

# -n and -G are mutually exclusive
if [ -n "$namespace" ] && [ "$global_principal" = "true" ]; then
    echo "Error: -n NAMESPACE and -G are mutually exclusive"
    show_help
fi

# Get admin token
TOKEN=$(curl --fail -s -X POST \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=admin" \
    -d "password=admin" \
    "http://keycloak.oidc.svc.cluster.local:9090/realms/master/protocol/openid-connect/token" | jq -r .access_token)

if [ -z "$TOKEN" ]; then
    echo "Error: Failed to get admin token"
    exit 1
fi

# Build attributes block from -n / -G. Keycloak expects each attribute
# value as a JSON array of strings.
attributes_json=""
if [ -n "$namespace" ]; then
    attributes_json="\"weaviate_namespace\": [\"$namespace\"]"
fi
if [ "$global_principal" = "true" ]; then
    [ -n "$attributes_json" ] && attributes_json="$attributes_json, "
    attributes_json="${attributes_json}\"weaviate_global_principal\": [\"true\"]"
fi

# Compose final body. Only include "attributes" key if at least one is set,
# so existing realms / tests that don't use these fields are unaffected.
if [ -n "$attributes_json" ]; then
    user_body=$(cat <<EOF
{
    "username": "$username",
    "enabled": true,
    "email": "$username@gmail.com",
    "emailVerified": true,
    "credentials": [{"type": "password", "value": "$username"}],
    "attributes": { $attributes_json }
}
EOF
)
else
    user_body=$(cat <<EOF
{
    "username": "$username",
    "enabled": true,
    "email": "$username@gmail.com",
    "emailVerified": true,
    "credentials": [{"type": "password", "value": "$username"}]
}
EOF
)
fi

# Create user
response=$(curl -s -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$user_body" \
    "http://keycloak.oidc.svc.cluster.local:9090/admin/realms/weaviate/users")

# Get user id from location header
user_id=$(curl -s -X GET \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "http://keycloak.oidc.svc.cluster.local:9090/admin/realms/weaviate/users?username=$username" | jq -r '.[0].id')

if [ -z "$user_id" ]; then
    echo "Error: Failed to create user or get user ID"
    exit 1
fi

# If group is provided, assign user to group
if [ ! -z ${group+x} ]; then
    # Get group id
    group_id=$(curl -s -X GET \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        "http://keycloak.oidc.svc.cluster.local:9090/admin/realms/weaviate/groups?search=$group" | jq -r '.[0].id')

    if [ ! -z "$group_id" ]; then
        # Add user to group
        curl -s -X PUT \
            -H "Authorization: Bearer $TOKEN" \
            "http://keycloak.oidc.svc.cluster.local:9090/admin/realms/weaviate/users/$user_id/groups/$group_id"
        echo "User $username created and added to group $group"
    else
        echo "User $username created but group $group not found"
    fi
else
    echo "User $username created successfully"
fi
