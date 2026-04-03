import os
import json
import logging
from datetime import datetime, timezone


def store_results(site_id: str, file_path: str, tables: list) -> str:
    """Store table extraction and summarization results as JSON in Blob Storage.

    Args:
        site_id: SharePoint site ID (used in blob path).
        file_path: Original file path in SharePoint.
        tables: List of table dicts with markdown and summary.

    Returns:
        The blob name where results were stored.
    """
    file_name = file_path.rstrip("/").split("/")[-1]
    base_name = os.path.splitext(file_name)[0]
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    safe_site_id = site_id.replace(",", "_").replace(".", "_")
    blob_name = f"{safe_site_id}/{base_name}_{timestamp}.json"

    result_doc = {
        "source": {
            "site_id": site_id,
            "file_path": file_path,
            "processed_at": timestamp,
        },
        "table_count": len(tables),
        "tables": tables,
    }

    from azure.storage.blob import BlobServiceClient

    conn_str = os.environ.get("SUMMARIES_STORAGE_CONNECTION_STR", "")
    container_name = os.environ.get("SUMMARIES_CONTAINER", "summaries")

    blob_service = BlobServiceClient.from_connection_string(conn_str)
    container_client = blob_service.get_container_client(container_name)
    blob_client = container_client.get_blob_client(blob_name)

    blob_client.upload_blob(
        json.dumps(result_doc, indent=2, ensure_ascii=False),
        content_type="application/json",
        overwrite=True,
    )

    logging.info(f"Stored results to blob: {container_name}/{blob_name}")
    return blob_name
