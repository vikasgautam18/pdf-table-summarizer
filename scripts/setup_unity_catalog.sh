#!/bin/bash
# Create a Unity Catalog storage credential and external location
# for the ADLS Gen2 account used by Delta Tables.
#
# This is required before registering external tables in Unity Catalog.
# Uses the Databricks Unity Catalog REST API (not SQL) for credential
# and location creation, since Azure service principal credentials
# cannot be created via SQL.
#
# Prerequisites:
#   - DATABRICKS_HOST and DATABRICKS_TOKEN environment variables set
#   - User must be a metastore admin or have CREATE STORAGE CREDENTIAL
#     and CREATE EXTERNAL LOCATION privileges
#   - The service principal must have Storage Blob Data Contributor
#     on the ADLS Gen2 account
#
# Usage:
#   ./scripts/setup_unity_catalog.sh --client-id <app-id> --client-secret <secret> --tenant-id <tenant-id>

set -euo pipefail

# --- Configuration ----------------------------------------------
DELTA_STORAGE_ACCOUNT="${DELTA_STORAGE_ACCOUNT:-<your-adls-account>}"
DELTA_CONTAINER="${DELTA_CONTAINER:-delta-tables}"
CREDENTIAL_NAME="${CREDENTIAL_NAME:-pdftblsum-adls-credential}"
LOCATION_NAME="${LOCATION_NAME:-pdftblsum-delta-tables}"

ADLS_URL="abfss://${DELTA_CONTAINER}@${DELTA_STORAGE_ACCOUNT}.dfs.core.windows.net/"

# Parse arguments
CLIENT_ID=""
CLIENT_SECRET=""
TENANT_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --client-id)
            CLIENT_ID="$2"
            shift 2
            ;;
        --client-secret)
            CLIENT_SECRET="$2"
            shift 2
            ;;
        --tenant-id)
            TENANT_ID="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo ""
            echo "Usage:"
            echo "  $0 --client-id <id> --client-secret <secret> --tenant-id <tenant>"
            exit 1
            ;;
    esac
done

if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ] || [ -z "$TENANT_ID" ]; then
    echo "Error: --client-id, --client-secret, and --tenant-id are all required"
    echo ""
    echo "Usage:"
    echo "  $0 --client-id <id> --client-secret <secret> --tenant-id <tenant>"
    exit 1
fi

if [ -z "${DATABRICKS_HOST:-}" ] || [ -z "${DATABRICKS_TOKEN:-}" ]; then
    echo "Error: DATABRICKS_HOST and DATABRICKS_TOKEN must be set"
    exit 1
fi

echo "================================================="
echo "   Setup Unity Catalog Storage Access"
echo "================================================="
echo ""
echo "Storage Account:    $DELTA_STORAGE_ACCOUNT"
echo "Container:          $DELTA_CONTAINER"
echo "ADLS URL:           $ADLS_URL"
echo "Credential Name:    $CREDENTIAL_NAME"
echo "Location Name:      $LOCATION_NAME"
echo "Databricks Host:    $DATABRICKS_HOST"
echo ""

# --- Step 0: Ensure SP has Storage Blob Data Contributor on ADLS Gen2 --------
echo "> Ensuring service principal has Storage Blob Data Contributor on ADLS Gen2..."
DELTA_STORAGE_ID=$(az storage account show \
    --name "$DELTA_STORAGE_ACCOUNT" \
    --query id -o tsv 2>/dev/null)

if [ -z "$DELTA_STORAGE_ID" ]; then
    echo "  Warning: could not find storage account $DELTA_STORAGE_ACCOUNT"
    echo "  Skipping RBAC assignment - ensure it is done manually"
else
    az role assignment create \
        --assignee "$CLIENT_ID" \
        --role "Storage Blob Data Contributor" \
        --scope "$DELTA_STORAGE_ID" \
        --output none 2>/dev/null && \
        echo "  Granted (or already assigned)" || \
        echo "  Warning: could not assign role - ensure it is done manually"
fi

# --- Step 1a: Delete existing external location (must be removed before credential) ---
echo "> Removing existing external location (if any): $LOCATION_NAME"
DEL_LOC_RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE \
    "${DATABRICKS_HOST}/api/2.1/unity-catalog/external-locations/${LOCATION_NAME}?force=true" \
    -H "Authorization: Bearer ${DATABRICKS_TOKEN}")
DEL_LOC_CODE=$(echo "$DEL_LOC_RESPONSE" | tail -1)
DEL_LOC_BODY=$(echo "$DEL_LOC_RESPONSE" | sed '$d')
if [ "$DEL_LOC_CODE" = "200" ]; then
    echo "  Deleted existing external location"
elif [ "$DEL_LOC_CODE" = "404" ]; then
    echo "  No existing external location found"
else
    echo "  Could not delete (HTTP $DEL_LOC_CODE) - will try to update instead"
fi

# --- Step 1b: Delete existing storage credential ---
echo ""
echo "> Removing existing storage credential (if any): $CREDENTIAL_NAME"
DEL_CRED_RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE \
    "${DATABRICKS_HOST}/api/2.1/unity-catalog/storage-credentials/${CREDENTIAL_NAME}?force=true" \
    -H "Authorization: Bearer ${DATABRICKS_TOKEN}")
DEL_CRED_CODE=$(echo "$DEL_CRED_RESPONSE" | tail -1)
if [ "$DEL_CRED_CODE" = "200" ]; then
    echo "  Deleted existing storage credential"
elif [ "$DEL_CRED_CODE" = "404" ]; then
    echo "  No existing storage credential found"
else
    echo "  Could not delete (HTTP $DEL_CRED_CODE) - will try to update instead"
fi

# --- Step 2: Create Storage Credential via REST API -------------
echo ""
echo "> Creating storage credential: $CREDENTIAL_NAME"

CRED_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'name': sys.argv[1],
    'azure_service_principal': {
        'directory_id': sys.argv[2],
        'application_id': sys.argv[3],
        'client_secret': sys.argv[4]
    },
    'comment': 'ADLS Gen2 access for PDF Table Summarizer Delta Tables'
}))
" "$CREDENTIAL_NAME" "$TENANT_ID" "$CLIENT_ID" "$CLIENT_SECRET")

CRED_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    "${DATABRICKS_HOST}/api/2.1/unity-catalog/storage-credentials" \
    -H "Authorization: Bearer ${DATABRICKS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$CRED_PAYLOAD")

CRED_HTTP_CODE=$(echo "$CRED_RESPONSE" | tail -1)
CRED_BODY=$(echo "$CRED_RESPONSE" | sed '$d')

if [ "$CRED_HTTP_CODE" = "200" ]; then
    echo "  Created: $CREDENTIAL_NAME"
elif echo "$CRED_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error_code',''))" 2>/dev/null | grep -q "ALREADY_EXISTS"; then
    echo "  Already exists, updating..."
    CRED_UPDATE=$(curl -s -w "\n%{http_code}" -X PATCH \
        "${DATABRICKS_HOST}/api/2.1/unity-catalog/storage-credentials/${CREDENTIAL_NAME}" \
        -H "Authorization: Bearer ${DATABRICKS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$CRED_PAYLOAD")
    CRED_UPD_CODE=$(echo "$CRED_UPDATE" | tail -1)
    if [ "$CRED_UPD_CODE" = "200" ]; then
        echo "  Updated: $CREDENTIAL_NAME"
    else
        echo "  Update failed (HTTP $CRED_UPD_CODE)"
    fi
else
    echo "  Failed (HTTP $CRED_HTTP_CODE):"
    echo "$CRED_BODY" | python3 -c "import sys,json; r=json.load(sys.stdin); print('  ', r.get('message', json.dumps(r)))" 2>/dev/null
fi

# --- Step 3: Create External Location via REST API --------------
echo ""
echo "> Creating external location: $LOCATION_NAME"

LOC_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'name': sys.argv[1],
    'url': sys.argv[2],
    'credential_name': sys.argv[3],
    'comment': 'ADLS Gen2 location for PDF Table Summarizer Delta Tables'
}))
" "$LOCATION_NAME" "$ADLS_URL" "$CREDENTIAL_NAME")

LOC_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    "${DATABRICKS_HOST}/api/2.1/unity-catalog/external-locations" \
    -H "Authorization: Bearer ${DATABRICKS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$LOC_PAYLOAD")

LOC_HTTP_CODE=$(echo "$LOC_RESPONSE" | tail -1)
LOC_BODY=$(echo "$LOC_RESPONSE" | sed '$d')

if [ "$LOC_HTTP_CODE" = "200" ]; then
    echo "  Created: $LOCATION_NAME"
elif echo "$LOC_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error_code',''))" 2>/dev/null | grep -q "ALREADY_EXISTS"; then
    echo "  Already exists, updating..."
    LOC_UPDATE=$(curl -s -w "\n%{http_code}" -X PATCH \
        "${DATABRICKS_HOST}/api/2.1/unity-catalog/external-locations/${LOCATION_NAME}" \
        -H "Authorization: Bearer ${DATABRICKS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$LOC_PAYLOAD")
    LOC_UPD_CODE=$(echo "$LOC_UPDATE" | tail -1)
    if [ "$LOC_UPD_CODE" = "200" ]; then
        echo "  Updated: $LOCATION_NAME"
    else
        echo "  Update failed (HTTP $LOC_UPD_CODE)"
    fi
else
    echo "  Failed (HTTP $LOC_HTTP_CODE):"
    echo "$LOC_BODY" | python3 -c "import sys,json; r=json.load(sys.stdin); print('  ', r.get('message', json.dumps(r)))" 2>/dev/null
fi

# --- Step 4: Validate credential via REST API -------------------
echo ""
echo "> Validating credential access to: $ADLS_URL"

VAL_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'storage_credential_name': sys.argv[1],
    'url': sys.argv[2]
}))
" "$CREDENTIAL_NAME" "$ADLS_URL")

VAL_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    "${DATABRICKS_HOST}/api/2.1/unity-catalog/validate-storage-credentials" \
    -H "Authorization: Bearer ${DATABRICKS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$VAL_PAYLOAD")

VAL_HTTP_CODE=$(echo "$VAL_RESPONSE" | tail -1)
VAL_BODY=$(echo "$VAL_RESPONSE" | sed '$d')

if [ "$VAL_HTTP_CODE" = "200" ]; then
    # Check validation results
    VALID=$(echo "$VAL_BODY" | python3 -c "
import sys, json
r = json.load(sys.stdin)
results = r.get('results', [])
all_ok = all(v.get('result') == 'PASS' for v in results)
if all_ok:
    print('PASS')
else:
    for v in results:
        if v.get('result') != 'PASS':
            print(f\"  {v.get('operation','?')}: {v.get('result','?')} - {v.get('message','')}\")
" 2>/dev/null)
    if [ "$VALID" = "PASS" ]; then
        echo "  Validation passed"
    else
        echo "  Validation issues:"
        echo "$VALID"
    fi
else
    echo "  Validation failed (HTTP $VAL_HTTP_CODE):"
    echo "$VAL_BODY" | python3 -c "import sys,json; r=json.load(sys.stdin); print('  ', r.get('message', json.dumps(r)))" 2>/dev/null
fi

echo ""
echo "================================================="
echo "   Unity Catalog setup complete"
echo "================================================="
echo ""
echo "Next steps:"
echo "  1. Register tables:  ./scripts/register_delta_tables.sh --catalog <your-catalog>"
echo "  2. Query in Databricks SQL:"
echo "     SELECT * FROM <catalog>.pdf_summarizer.processing_runs;"
echo "     SELECT * FROM <catalog>.pdf_summarizer.table_summaries;"
