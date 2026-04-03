import json
import os
import logging
import azure.functions as func


def process_pdf_impl(msg: func.QueueMessage) -> None:
    """Process a PDF from SharePoint: extract tables, summarize, and store results.

    Expected queue message format:
    {
        "siteId": "<sharepoint-site-id>",
        "filePath": "<path/to/file.pdf>"
    }

    Pipeline:
    1. Download PDF from SharePoint via Graph API
    2. Extract tables using Document Intelligence (prebuilt-layout)
    3. Summarize each table with Azure OpenAI GPT-4o
    4. Write results to Delta Tables on ADLS Gen2 (primary output)
    5. Optionally write results to Azure Blob Storage (secondary output)
    """
    from functions.sharepoint_client import download_file
    from functions.table_extractor import extract_tables
    from functions.summarizer import summarize_tables
    from functions.delta_writer import (
        write_processing_run, write_table_summaries, is_already_processed,
    )
    from functions.blob_store import store_results

    enable_blob = os.environ.get("ENABLE_BLOB_OUTPUT", "false").lower() == "true"

    payload = json.loads(msg.get_body().decode("utf-8"), strict=False)

    site_id = payload.get("siteId")
    file_path = payload.get("filePath")

    if not site_id or not file_path:
        logging.warning(
            f"Queue message missing siteId or filePath: {payload}. "
            "This may be a raw webhook notification that needs resolution. "
            "Skipping."
        )
        return

    if not file_path.lower().endswith(".pdf"):
        logging.info(f"Skipping non-PDF file: {file_path}")
        return

    # Skip if already processed successfully
    if is_already_processed(file_path):
        logging.info(f"Skipping already processed file: {file_path}")
        return

    logging.info(f"Processing PDF: {file_path} from site {site_id}")

    # Step 1: Download the PDF from SharePoint
    pdf_bytes = download_file(site_id, file_path)
    logging.info(f"Downloaded {len(pdf_bytes)} bytes")

    # Step 2: Extract tables using Document Intelligence
    tables = extract_tables(pdf_bytes)
    if not tables:
        logging.info(f"No tables found in {file_path}")
        write_processing_run(site_id, file_path, 0, "succeeded")
        if enable_blob:
            store_results(site_id, file_path, [])
        return

    logging.info(f"Extracted {len(tables)} table(s) from {file_path}")

    # Step 3: Summarize each table with Azure OpenAI
    tables = summarize_tables(tables)
    logging.info(f"Summarized {len(tables)} table(s)")

    # Step 4: Write results to Delta Tables on ADLS Gen2 (primary output)
    write_processing_run(site_id, file_path, len(tables), "succeeded")
    write_table_summaries(file_path, tables)
    logging.info(f"Delta Tables updated for {file_path}")

    # Step 5: Optionally write results to Blob Storage (secondary output)
    if enable_blob:
        blob_name = store_results(site_id, file_path, tables)
        logging.info(f"Blob output: {blob_name}")

    logging.info(
        f"Pipeline complete for {file_path}: {len(tables)} table(s) processed"
    )
