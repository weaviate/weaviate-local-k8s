#!/usr/bin/env bash

# Help function
function show_help() {
    echo "Usage: $0 -u USERNAME [-g GROUP]"
    echo
    echo "Create a user in Keycloak OIDC system"
    echo
    echo "Options:"
    echo "  -u USERNAME   Username to create (mandatory)"
    echo "  -g GROUP      Group to assign user to (optional)"
    echo "  -h           Show this help message"
    exit 1
}

# Parse command line arguments
while getopts "u:g:h" opt; do
    case $opt in
        u) username="$OPTARG";;
        g) group="$OPTARG";;
        h) show_help;;
        \?) echo "Invalid option -$OPTARG" >&2; show_help;;
    esac
done

# Check if username is provided
if [ -z "$username" ]; then
    echo "Error: Username is required"
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

# Create user
response=$(curl -s -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"username\": \"$username\",
        \"enabled\": true,
        \"email\": \"$username@gmail.com\",
        \"emailVerified\": true,
        \"credentials\": [{
            \"type\": \"password\",
            \"value\": \"$username\"
        }]
    }" \
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
