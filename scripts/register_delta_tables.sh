#!/bin/bash
# Register Delta Tables in Databricks as external tables
#
# This script creates external Delta Tables in Databricks that point to
# the ADLS Gen2 storage paths written by the Function App. This allows
# Databricks users to query the tables via SQL without any Databricks
# compute writing to them.
#
# Prerequisites:
#   - DATABRICKS_HOST and DATABRICKS_TOKEN environment variables set
#   - SQL Warehouse available (will auto-detect or set WAREHOUSE_ID)
#   - ADLS Gen2 storage account exists with Delta Tables written
#   - Databricks workspace has access to the ADLS Gen2 account
#     (via storage credential or external location in Unity Catalog,
#      or via cluster-level storage config for hive_metastore)
#
# Usage:
#   ./scripts/register_delta_tables.sh                          # defaults to hive_metastore
#   ./scripts/register_delta_tables.sh --catalog my_catalog     # use Unity Catalog
#   ./scripts/register_delta_tables.sh -c my_catalog            # short form

set -euo pipefail

# --- Configuration ----------------------------------------------
DELTA_STORAGE_ACCOUNT="${DELTA_STORAGE_ACCOUNT:-<your-adls-account>}"
DELTA_CONTAINER="${DELTA_CONTAINER:-delta-tables}"
DATABRICKS_HOST="${DATABRICKS_HOST:-<your-databricks-host>}"
CATALOG="hive_metastore"
SCHEMA="pdf_summarizer"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--catalog)
            CATALOG="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--catalog <catalog-name>]"
            exit 1
            ;;
    esac
done

FULL_SCHEMA="${CATALOG}.${SCHEMA}"
ADLS_BASE="abfss://${DELTA_CONTAINER}@${DELTA_STORAGE_ACCOUNT}.dfs.core.windows.net/pdf_summarizer"

# Validate env vars
if [ -z "${DATABRICKS_TOKEN:-}" ]; then
    echo "Error: DATABRICKS_TOKEN must be set"
    exit 1
fi

echo "================================================="
echo "   Register Delta Tables in Databricks"
echo "================================================="
echo ""
echo "Catalog:         $CATALOG"
echo "Schema:          $FULL_SCHEMA"
echo "ADLS Base Path:  $ADLS_BASE"
echo "Databricks Host: $DATABRICKS_HOST"
echo ""

# --- Helper: execute SQL via REST API ---------------------------
run_sql() {
    local statement="$1"
    local warehouse_id="${WAREHOUSE_ID:-}"

    # Auto-detect warehouse if not set
    if [ -z "$warehouse_id" ]; then
        warehouse_id=$(curl -s -X GET \
            "${DATABRICKS_HOST}/api/2.0/sql/warehouses" \
            -H "Authorization: Bearer ${DATABRICKS_TOKEN}" \
            | python3 -c "import sys,json; ws=json.load(sys.stdin).get('warehouses',[]); print(ws[0]['id'] if ws else '')" 2>/dev/null)
        if [ -z "$warehouse_id" ]; then
            echo "Error: no SQL Warehouse found. Create one or set WAREHOUSE_ID."
            return 1
        fi
    fi

    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'warehouse_id': sys.argv[1],
    'statement': sys.argv[2],
    'wait_timeout': '30s'
}))
" "$warehouse_id" "$statement")

    local response
    response=$(curl -s -X POST \
        "${DATABRICKS_HOST}/api/2.0/sql/statements/" \
        -H "Authorization: Bearer ${DATABRICKS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload")

    local status
    status=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',{}).get('state','UNKNOWN'))" 2>/dev/null)

    if [ "$status" = "SUCCEEDED" ]; then
        return 0
    else
        local error_msg
        error_msg=$(echo "$response" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('status',{}).get('error',{}).get('message', json.dumps(r)))" 2>/dev/null)
        echo "  Error: $error_msg"
        return 1
    fi
}

# Create schema if not exists
echo "> Creating schema: $FULL_SCHEMA"
run_sql "CREATE SCHEMA IF NOT EXISTS ${FULL_SCHEMA}" && \
    echo "  Created: $FULL_SCHEMA" || \
    echo "  Schema may already exist"

# Register processing_runs table
echo ""
echo "> Registering table: ${FULL_SCHEMA}.processing_runs"
run_sql "CREATE TABLE IF NOT EXISTS ${FULL_SCHEMA}.processing_runs (file_name STRING, site_id STRING, processed_at TIMESTAMP, table_count INT, status STRING, error_message STRING) USING DELTA LOCATION '${ADLS_BASE}/processing_runs' COMMENT 'One row per PDF processed - written by Function App via deltalake library'" && \
    echo "  Registered: ${FULL_SCHEMA}.processing_runs" || \
    echo "  Failed - see error above"

# Register table_summaries table
echo ""
echo "> Registering table: ${FULL_SCHEMA}.table_summaries"
run_sql "CREATE TABLE IF NOT EXISTS ${FULL_SCHEMA}.table_summaries (file_name STRING, table_index INT, page INT, row_count INT, column_count INT, markdown STRING, summary STRING, processed_at TIMESTAMP) USING DELTA LOCATION '${ADLS_BASE}/table_summaries' COMMENT 'One row per extracted table - written by Function App via deltalake library'" && \
    echo "  Registered: ${FULL_SCHEMA}.table_summaries" || \
    echo "  Failed - see error above"

echo ""
echo "================================================="
echo "   Delta Tables registered"
echo "================================================="
echo ""
echo "You can now query these tables in Databricks:"
echo ""
echo "  SELECT * FROM ${FULL_SCHEMA}.processing_runs ORDER BY processed_at DESC;"
echo "  SELECT * FROM ${FULL_SCHEMA}.table_summaries ORDER BY processed_at DESC;"
echo ""
if [ "$CATALOG" != "hive_metastore" ]; then
    echo "Note: For Unity Catalog, ensure a storage credential and external location"
    echo "exist for: abfss://${DELTA_CONTAINER}@${DELTA_STORAGE_ACCOUNT}.dfs.core.windows.net/"
    echo "Run: ./scripts/setup_unity_catalog.sh --help"
fi
