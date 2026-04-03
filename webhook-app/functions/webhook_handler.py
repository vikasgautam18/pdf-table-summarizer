import json
import logging
import os
import azure.functions as func


def webhook_handler_impl(req: func.HttpRequest) -> func.HttpResponse:
    """Handle SharePoint/Graph webhook validation and change notifications.

    Graph API subscriptions send validation with ?validationToken=<token>.
    SharePoint webhooks send ?validationtoken=<token>.
    We handle both cases.

    On change notifications, resolves the changed files via Graph API
    and enqueues messages in the format expected by process_pdf:
    {"siteId": "...", "filePath": "filename.pdf"}
    """
    # Phase 1: Webhook validation (handle both casing variants)
    validation_token = req.params.get("validationToken") or req.params.get("validationtoken")
    if validation_token:
        logging.info("Webhook validation request received")
        return func.HttpResponse(
            validation_token,
            status_code=200,
            headers={"Content-Type": "text/plain"},
        )

    # Phase 2: Change notification
    try:
        body = req.get_json()
    except ValueError:
        logging.warning("Webhook received non-JSON body")
        return func.HttpResponse("Invalid request body", status_code=400)

    notifications = body.get("value", [])
    logging.info(f"Received {len(notifications)} webhook notification(s)")

    # Verify clientState to reject spoofed notifications
    expected_state = os.environ.get("WEBHOOK_CLIENT_STATE", "pdf-table-summarizer")
    notifications = [
        n for n in notifications
        if n.get("clientState") == expected_state
    ]
    if not notifications:
        logging.warning("No notifications matched expected clientState")
        return func.HttpResponse(status_code=200)

    from azure.storage.queue import QueueClient
    site_id = os.environ.get("SHAREPOINT_SITE_ID", "")
    if not site_id:
        logging.error("SHAREPOINT_SITE_ID not configured")
        return func.HttpResponse("Server misconfigured", status_code=500)

    queue_connection = os.environ["AzureWebJobsStorage"]
    queue_client = QueueClient.from_connection_string(
        queue_connection, queue_name="pdf-processing"
    )

    enqueued = 0
    for notification in notifications:
        resource = notification.get("resource", "")

        # Extract list ID from the resource string
        # Format: "sites/{siteId}/lists/{listId}"
        list_id = _extract_list_id(resource)
        if not list_id:
            logging.warning(f"Could not extract list ID from resource: {resource}")
            continue

        # Resolve recently changed PDF files from the list
        try:
            pdf_files = _get_recent_pdfs(site_id, list_id)
        except Exception as e:
            logging.error(f"Failed to resolve files from list {list_id}: {e}")
            continue

        for file_name in pdf_files:
            message = {
                "siteId": site_id,
                "filePath": file_name,
            }
            queue_client.send_message(json.dumps(message))
            enqueued += 1
            logging.info(f"Enqueued PDF for processing: {file_name}")

    logging.info(f"Enqueued {enqueued} message(s) to pdf-processing queue")
    return func.HttpResponse(status_code=200)


def _extract_list_id(resource: str) -> str:
    """Extract list ID from a SharePoint webhook resource string."""
    # resource format: "sites/{siteId}/lists/{listId}"
    parts = resource.split("/")
    try:
        list_idx = parts.index("lists")
        return parts[list_idx + 1]
    except (ValueError, IndexError):
        return ""


def _get_recent_pdfs(site_id: str, list_id: str) -> list:
    """Get recently changed PDF file names from a SharePoint list."""
    import requests
    from functions.sharepoint_client import _get_graph_token

    token = _get_graph_token()
    headers = {"Authorization": f"Bearer {token}"}

    url = (
        f"https://graph.microsoft.com/v1.0/sites/{site_id}"
        f"/lists/{list_id}/items?$expand=driveItem"
        f"&$filter=contentType/name eq 'Document'"
        f"&$orderby=lastModifiedDateTime desc&$top=5"
    )
    resp = requests.get(url, headers=headers, timeout=30)
    resp.raise_for_status()

    pdf_files = []
    for item in resp.json().get("value", []):
        drive_item = item.get("driveItem", {})
        name = drive_item.get("name", "")
        if name.lower().endswith(".pdf"):
            pdf_files.append(name)

    return pdf_files
