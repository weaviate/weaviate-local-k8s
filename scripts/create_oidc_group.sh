#!/usr/bin/env bash

# Help function
function show_help() {
    echo "Usage: $0 -g GROUP"
    echo
    echo "Create a group in Keycloak OIDC system"
    echo
    echo "Options:"
    echo "  -g GROUP     Group name to create (mandatory)"
    echo "  -h          Show this help message"
    exit 1
}

# Parse command line arguments
while getopts "g:h" opt; do
    case $opt in
        g) group="$OPTARG";;
        h) show_help;;
        \?) echo "Invalid option -$OPTARG" >&2; show_help;;
    esac
done

# Check if group is provided
if [ -z "$group" ]; then
    echo "Error: Group name is required"
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

# Create group
response=$(curl -s -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"$group\"
    }" \
    "http://keycloak.oidc.svc.cluster.local:9090/admin/realms/weaviate/groups")

# Verify group was created by trying to fetch it
group_id=$(curl -s -X GET \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "http://keycloak.oidc.svc.cluster.local:9090/admin/realms/weaviate/groups?search=$group" | jq -r '.[0].id')

if [ ! -z "$group_id" ]; then
    echo "Group $group created successfully"
else
    echo "Error: Failed to create group $group"
    exit 1
fi
