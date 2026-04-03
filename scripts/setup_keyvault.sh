#!/bin/bash
# Store secrets in Azure Key Vault
#
# This script stores the Graph API client secret (and optionally other secrets)
# in Azure Key Vault. The Function App references these via
# @Microsoft.KeyVault(VaultName=...;SecretName=...) syntax in app settings.
#
# Prerequisites:
#   - Azure CLI (az) logged in with Key Vault write access
#   - Key Vault exists (created by Terraform)
#
# Usage:
#   ./scripts/setup_keyvault.sh
#   ./scripts/setup_keyvault.sh --secret "<client-secret-value>"

set -euo pipefail

# --- Configuration ----------------------------------------------
KEY_VAULT_NAME="kv-pdftblsum"
RESOURCE_GROUP="rg-pdftblsum"

echo "================================================="
echo "   Store Secrets in Key Vault"
echo "================================================="
echo ""

# Parse arguments
CLIENT_SECRET=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --secret)
            CLIENT_SECRET="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--secret <client-secret-value>]"
            exit 1
            ;;
    esac
done

# Prompt for secret if not provided via argument
if [ -z "$CLIENT_SECRET" ]; then
    read -rsp "Enter Graph API Client Secret: " CLIENT_SECRET
    echo
fi

if [ -z "$CLIENT_SECRET" ]; then
    echo "Client secret cannot be empty"
    exit 1
fi

# Verify Key Vault exists
echo "> Verifying Key Vault ($KEY_VAULT_NAME)..."
az keyvault show --name "$KEY_VAULT_NAME" --resource-group "$RESOURCE_GROUP" \
    --query "{name:name, location:location}" -o table 2>/dev/null || {
    echo "Key Vault not found. Run 'terraform apply' first."
    exit 1
}

# Store the Graph client secret
echo ""
echo "> Storing graph-client-secret..."
az keyvault secret set \
    --vault-name "$KEY_VAULT_NAME" \
    --name "graph-client-secret" \
    --value "$CLIENT_SECRET" \
    --output none

echo "  Stored: graph-client-secret"

echo ""
echo "================================================="
echo "   Secrets stored in Key Vault"
echo "================================================="
echo ""
echo "The Function App references this secret via app settings:"
echo "  GRAPH_CLIENT_SECRET = @Microsoft.KeyVault(VaultName=$KEY_VAULT_NAME;SecretName=graph-client-secret)"
echo ""
echo "To verify:"
echo "  az keyvault secret list --vault-name $KEY_VAULT_NAME -o table"
