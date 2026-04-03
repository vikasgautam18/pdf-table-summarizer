#!/bin/bash
# Set up IAM (RBAC) role assignments for the Function App Managed Identity
#
# This script assigns the required roles to the Function App's system-assigned
# Managed Identity so it can access:
#   - ADLS Gen2 (Delta Tables)
#   - Blob Storage (queues, summaries)
#   - Azure AI Services (GPT-4o, Document Intelligence)
#   - Azure Key Vault (Graph client secret)
#
# Prerequisites:
#   - Azure CLI (az) logged in with Owner/User Access Administrator role
#   - Terraform applied (resources exist)
#
# Usage:
#   ./scripts/setup_iam.sh

set -euo pipefail

# --- Configuration ----------------------------------------------
RESOURCE_GROUP="rg-pdftblsum"
FUNC_APP_NAME="func-pdftblsum"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-<your-storage-account>}"
DELTA_STORAGE_ACCOUNT="${DELTA_STORAGE_ACCOUNT:-<your-adls-account>}"
AI_SERVICES_NAME="${AI_SERVICES_NAME:-pdftblsum-ai-services}"
DOC_INTEL_NAME="${DOC_INTEL_NAME:-pdftblsum-doc-intel}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-kv-pdftblsum}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-<your-azure-subscription-id>}"

echo "================================================="
echo "   Setup IAM Role Assignments"
echo "================================================="
echo ""

# Get the Function App Managed Identity principal ID
echo "> Getting Function App Managed Identity..."
PRINCIPAL_ID=$(az functionapp identity show \
    --name "$FUNC_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query principalId -o tsv)

if [ -z "$PRINCIPAL_ID" ]; then
    echo "Managed Identity not found. Ensure the Function App has system-assigned MI enabled."
    exit 1
fi
echo "  Principal ID: $PRINCIPAL_ID"

# --- ADLS Gen2: Storage Blob Data Contributor -------------------
echo ""
echo "> Granting Storage Blob Data Contributor on ADLS Gen2 ($DELTA_STORAGE_ACCOUNT)..."
DELTA_STORAGE_ID=$(az storage account show \
    --name "$DELTA_STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --query id -o tsv)

az role assignment create \
    --assignee "$PRINCIPAL_ID" \
    --role "Storage Blob Data Contributor" \
    --scope "$DELTA_STORAGE_ID" \
    --output none 2>/dev/null && echo "  Done" || echo "  Already assigned"

# --- Blob Storage: Storage Blob Data Contributor ----------------
echo ""
echo "> Granting Storage Blob Data Contributor on Blob Storage ($STORAGE_ACCOUNT)..."
STORAGE_ID=$(az storage account show \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --query id -o tsv)

az role assignment create \
    --assignee "$PRINCIPAL_ID" \
    --role "Storage Blob Data Contributor" \
    --scope "$STORAGE_ID" \
    --output none 2>/dev/null && echo "  Done" || echo "  Already assigned"

# --- AI Services: Cognitive Services User -----------------------
echo ""
echo "> Granting Cognitive Services User on AI Services ($AI_SERVICES_NAME)..."
AI_ID=$(az cognitiveservices account show \
    --name "$AI_SERVICES_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query id -o tsv)

az role assignment create \
    --assignee "$PRINCIPAL_ID" \
    --role "Cognitive Services User" \
    --scope "$AI_ID" \
    --output none 2>/dev/null && echo "  Done" || echo "  Already assigned"

# --- Document Intelligence: Cognitive Services User -------------
echo ""
echo "> Granting Cognitive Services User on Document Intelligence ($DOC_INTEL_NAME)..."
DOC_INTEL_ID=$(az cognitiveservices account show \
    --name "$DOC_INTEL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query id -o tsv)

az role assignment create \
    --assignee "$PRINCIPAL_ID" \
    --role "Cognitive Services User" \
    --scope "$DOC_INTEL_ID" \
    --output none 2>/dev/null && echo "  Done" || echo "  Already assigned"

# --- Key Vault: Key Vault Secrets User --------------------------
echo ""
echo "> Granting Key Vault Secrets User on Key Vault ($KEY_VAULT_NAME)..."
KV_ID=$(az keyvault show \
    --name "$KEY_VAULT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query id -o tsv)

az role assignment create \
    --assignee "$PRINCIPAL_ID" \
    --role "Key Vault Secrets User" \
    --scope "$KV_ID" \
    --output none 2>/dev/null && echo "  Done" || echo "  Already assigned"

echo ""
echo "================================================="
echo "   All IAM role assignments complete"
echo "================================================="
echo ""
echo "Summary of roles assigned to Function App MI ($PRINCIPAL_ID):"
echo "  - Storage Blob Data Contributor > $DELTA_STORAGE_ACCOUNT (ADLS Gen2)"
echo "  - Storage Blob Data Contributor > $STORAGE_ACCOUNT (Blob Storage)"
echo "  - Cognitive Services User       > $AI_SERVICES_NAME"
echo "  - Cognitive Services User       > $DOC_INTEL_NAME"
echo "  - Key Vault Secrets User        > $KEY_VAULT_NAME"
