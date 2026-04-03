#!/bin/bash
# Deploy the webhook-app Function App code to Azure
#
# Prerequisites:
#   - Azure Functions Core Tools (func) installed
#   - Azure CLI (az) logged in
#   - Terraform applied (function app exists)
#
# Usage:
#   ./scripts/setup_function_app.sh [function-app-name]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default function app name from Terraform
FUNC_APP_NAME="${1:-func-pdftblsum}"

echo "================================================="
echo "   Deploy Webhook Function App"
echo "================================================="
echo ""
echo "Function App: $FUNC_APP_NAME"
echo "Source:        $PROJECT_ROOT/webhook-app"
echo ""

# Verify Azure CLI login
echo "> Checking Azure CLI login..."
az account show --query "{subscription:name, id:id}" -o table 2>/dev/null || {
    echo "Not logged in to Azure CLI. Run: az login"
    exit 1
}

# Verify func CLI
command -v func >/dev/null 2>&1 || {
    echo "Azure Functions Core Tools not found. Install from:"
    echo "   https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local"
    exit 1
}

# Install Python dependencies
echo ""
echo "> Installing Python dependencies..."
cd "$PROJECT_ROOT/webhook-app"
pip install -r requirements.txt --quiet --target .python_packages/lib/site-packages

# Deploy to Azure
echo ""
echo "> Publishing Function App to Azure..."
func azure functionapp publish "$FUNC_APP_NAME" --python

echo ""
echo "Function App deployed successfully!"
echo ""
echo "Webhook URL:"
echo "  https://${FUNC_APP_NAME}.azurewebsites.net/api/webhook?code=<function-key>"
echo ""
echo "To get the function key:"
echo "  az functionapp keys list -g rg-pdftblsum -n $FUNC_APP_NAME --query functionKeys"
