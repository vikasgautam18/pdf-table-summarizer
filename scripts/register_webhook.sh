#!/bin/bash
# Register a SharePoint webhook subscription on a document library
#
# This script:
# 1. Gets a Graph API token using the app registration credentials
# 2. Discovers the document library (list) ID
# 3. Gets the Function App webhook URL and function key
# 4. Registers a webhook subscription on the document library
#
# Prerequisites:
#   - Azure CLI (az) logged in
#   - Function App deployed with webhook_handler function
#   - App registration with Sites.ReadWrite.All permission
#
# Usage:
#   ./scripts/register_webhook.sh
#
# Environment variables (optional overrides):
#   GRAPH_TENANT_ID, GRAPH_CLIENT_ID, GRAPH_CLIENT_SECRET
#   SHAREPOINT_SITE_ID, FUNC_APP_NAME, RESOURCE_GROUP

set -euo pipefail

# --- Configuration ----------------------------------------------
GRAPH_TENANT_ID="${GRAPH_TENANT_ID:-<your-entra-tenant-id>}"
GRAPH_CLIENT_ID="${GRAPH_CLIENT_ID:-<your-app-client-id>}"
SHAREPOINT_SITE_ID="${SHAREPOINT_SITE_ID:-<your-sharepoint-site-id>}"
WEBHOOK_CLIENT_STATE="${WEBHOOK_CLIENT_STATE:-pdf-table-summarizer}"
FUNC_APP_NAME="${FUNC_APP_NAME:-func-pdftblsum}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-pdftblsum}"

# Webhook expiration (max 30 days for SharePoint list subscriptions)
EXPIRY=$(python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) + timedelta(days=29)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")

echo "================================================="
echo "   Register SharePoint Webhook"
echo "================================================="
echo ""
echo "Site ID:         $SHAREPOINT_SITE_ID"
echo "Function App:    $FUNC_APP_NAME"
echo "Expiration:      $EXPIRY"
echo ""

# --- Step 1: Get Graph API token --------------------------------
echo "> Getting Graph API token..."

if [ -z "${GRAPH_CLIENT_SECRET:-}" ]; then
    # Try getting from Function App settings
    GRAPH_CLIENT_SECRET=$(az functionapp config appsettings list \
        -g "$RESOURCE_GROUP" -n "$FUNC_APP_NAME" \
        --query "[?name=='GRAPH_CLIENT_SECRET'].value" -o tsv 2>/dev/null)
    if [ -z "$GRAPH_CLIENT_SECRET" ]; then
        echo "Error: GRAPH_CLIENT_SECRET not set and could not read from Function App"
        echo "Set it: export GRAPH_CLIENT_SECRET='<your-secret>'"
        exit 1
    fi
fi

TOKEN_RESPONSE=$(curl -s -X POST \
    "https://login.microsoftonline.com/${GRAPH_TENANT_ID}/oauth2/v2.0/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${GRAPH_CLIENT_ID}&client_secret=${GRAPH_CLIENT_SECRET}&scope=https://graph.microsoft.com/.default")

GRAPH_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

if [ -z "$GRAPH_TOKEN" ]; then
    echo "Error: Failed to get Graph API token"
    echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('error_description', json.dumps(r)))" 2>/dev/null
    exit 1
fi
echo "  Token acquired"

# --- Step 2: Find document library list ID ----------------------
echo ""
echo "> Finding document library..."

LISTS_RESPONSE=$(curl -s \
    "https://graph.microsoft.com/v1.0/sites/${SHAREPOINT_SITE_ID}/lists" \
    -H "Authorization: Bearer ${GRAPH_TOKEN}")

LIST_INFO=$(echo "$LISTS_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
lists = data.get('value', [])
# Find the first document library
for lib in lists:
    tmpl = lib.get('list', {}).get('template', '')
    if tmpl == 'documentLibrary':
        print(f\"{lib['id']}:{lib['displayName']}\")
        break
else:
    print('ERROR:No document libraries found')
" 2>/dev/null)

if echo "$LIST_INFO" | grep -q "^ERROR:"; then
    echo "  ${LIST_INFO#ERROR:}"
    exit 1
fi

LIST_ID=$(echo "$LIST_INFO" | cut -d: -f1)
LIST_NAME=$(echo "$LIST_INFO" | cut -d: -f2-)
echo "  Found: $LIST_NAME (ID: $LIST_ID)"

# --- Step 3: Get Function App webhook URL -----------------------
echo ""
echo "> Getting Function App key..."

FUNC_KEYS=$(az functionapp keys list \
    -g "$RESOURCE_GROUP" -n "$FUNC_APP_NAME" \
    --query "functionKeys" -o json 2>/dev/null)

FUNC_KEY=$(echo "$FUNC_KEYS" | python3 -c "
import sys, json
keys = json.load(sys.stdin)
if isinstance(keys, dict):
    print(next(iter(keys.values()), ''))
else:
    print('')
" 2>/dev/null)

if [ -z "$FUNC_KEY" ]; then
    echo "  No function key found, trying default key..."
    FUNC_KEY=$(az functionapp keys list \
        -g "$RESOURCE_GROUP" -n "$FUNC_APP_NAME" \
        --query "masterKey" -o tsv 2>/dev/null)
fi

if [ -z "$FUNC_KEY" ]; then
    echo "Error: Could not get Function App key"
    exit 1
fi

WEBHOOK_URL="https://${FUNC_APP_NAME}.azurewebsites.net/api/webhook?code=${FUNC_KEY}"
echo "  Webhook URL ready"

# --- Step 4: Register webhook subscription ----------------------
echo ""
echo "> Registering webhook subscription..."

SUB_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'changeType': 'updated',
    'notificationUrl': sys.argv[1],
    'resource': f'sites/{sys.argv[2]}/lists/{sys.argv[3]}',
    'expirationDateTime': sys.argv[4],
    'clientState': sys.argv[5]
}))
" "$WEBHOOK_URL" "$SHAREPOINT_SITE_ID" "$LIST_ID" "$EXPIRY" "$WEBHOOK_CLIENT_STATE")

SUB_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    "https://graph.microsoft.com/v1.0/subscriptions" \
    -H "Authorization: Bearer ${GRAPH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$SUB_PAYLOAD")

SUB_HTTP_CODE=$(echo "$SUB_RESPONSE" | tail -1)
SUB_BODY=$(echo "$SUB_RESPONSE" | sed '$d')

if [ "$SUB_HTTP_CODE" = "201" ]; then
    SUB_ID=$(echo "$SUB_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
    SUB_EXPIRY=$(echo "$SUB_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('expirationDateTime',''))" 2>/dev/null)
    echo "  Subscription created!"
    echo "  ID:      $SUB_ID"
    echo "  Expires: $SUB_EXPIRY"
else
    echo "  Failed (HTTP $SUB_HTTP_CODE):"
    echo "$SUB_BODY" | python3 -c "import sys,json; r=json.load(sys.stdin); err=r.get('error',{}); print(f\"  {err.get('code','')}: {err.get('message', json.dumps(r))}\")" 2>/dev/null
    exit 1
fi

echo ""
echo "================================================="
echo "   Webhook registered successfully"
echo "================================================="
echo ""
echo "SharePoint will now send notifications to your Function App"
echo "when documents are created or updated in '$LIST_NAME'."
echo ""
echo "IMPORTANT: Subscription expires on $SUB_EXPIRY"
echo "Set a reminder to renew it before expiration."
echo ""
echo "To list active subscriptions:"
echo "  curl -H 'Authorization: Bearer <token>' \\"
echo "    'https://graph.microsoft.com/v1.0/sites/$SHAREPOINT_SITE_ID/lists/$LIST_ID/subscriptions'"
