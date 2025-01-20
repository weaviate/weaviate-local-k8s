#!/usr/bin/env bash

# Help function
function show_help() {
    echo "Usage: $0 -u USERNAME [-p PASSWORD]"
    echo
    echo "Get OIDC token for a user from Keycloak"
    echo
    echo "Options:"
    echo "  -u USERNAME   Username to get token for (mandatory)"
    echo "  -p PASSWORD   Password for the user (optional, defaults to username)"
    echo "  -h           Show this help message"
    exit 1
}

# Parse command line arguments
while getopts "u:p:h" opt; do
    case $opt in
        u) username="$OPTARG";;
        p) password="$OPTARG";;
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

# Get user token
TOKEN=$(curl -s -X POST \
    -d "grant_type=password" \
    -d "client_id=demo" \
    -d "username=$username" \
    -d "password=$password" \
    "http://keycloak.oidc.svc.cluster.local:9090/realms/weaviate/protocol/openid-connect/token" | jq -r .access_token)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "Error: Failed to get token for user $username"
    exit 1
fi

echo "$TOKEN"
