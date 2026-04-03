import os
import logging
import requests


def _get_graph_token() -> str:
    """Acquire a Microsoft Graph API access token using client credentials."""
    from azure.identity import ClientSecretCredential
    credential = ClientSecretCredential(
        tenant_id=os.environ["GRAPH_TENANT_ID"],
        client_id=os.environ["GRAPH_CLIENT_ID"],
        client_secret=os.environ["GRAPH_CLIENT_SECRET"],
    )
    token = credential.get_token("https://graph.microsoft.com/.default")
    return token.token


def download_file(site_id: str, file_path: str) -> bytes:
    """Download a file from SharePoint via the Microsoft Graph API.

    Args:
        site_id: The SharePoint site ID.
        file_path: Path to the file relative to the drive root.

    Returns:
        The raw file bytes.
    """
    token = _get_graph_token()
    headers = {"Authorization": f"Bearer {token}"}

    item_url = (
        f"https://graph.microsoft.com/v1.0/sites/{site_id}"
        f"/drive/root:/{file_path}"
    )
    item_resp = requests.get(item_url, headers=headers, timeout=30)
    item_resp.raise_for_status()
    item = item_resp.json()

    download_url = item.get("@microsoft.graph.downloadUrl")
    if not download_url:
        raise ValueError(f"No download URL found for {file_path}")

    # Reject files exceeding size limit to prevent memory exhaustion
    file_size = item.get("size", 0)
    max_size_mb = int(os.environ.get("MAX_PDF_SIZE_MB", "100"))
    max_size = max_size_mb * 1024 * 1024
    if file_size > max_size:
        raise ValueError(
            f"File {file_path} is too large ({file_size} bytes, max {max_size_mb}MB)"
        )

    file_resp = requests.get(download_url, timeout=120)
    file_resp.raise_for_status()

    logging.info(f"Downloaded {file_path} ({len(file_resp.content)} bytes)")
    return file_resp.content


def get_changes(site_id: str, list_id: str) -> list:
    """Fetch recent changes for a SharePoint list (used by webhook handler).

    Args:
        site_id: The SharePoint site ID.
        list_id: The SharePoint list (document library) ID.

    Returns:
        List of changed item dicts.
    """
    token = _get_graph_token()
    headers = {"Authorization": f"Bearer {token}"}

    changes_url = (
        f"https://graph.microsoft.com/v1.0/sites/{site_id}"
        f"/lists/{list_id}/items?$expand=driveItem"
        f"&$filter=contentType/name eq 'Document'"
        f"&$orderby=lastModifiedDateTime desc&$top=10"
    )
    resp = requests.get(changes_url, headers=headers, timeout=30)
    resp.raise_for_status()
    return resp.json().get("value", [])
