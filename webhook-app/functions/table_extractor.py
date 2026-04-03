import os
import base64
import logging


def extract_tables(pdf_bytes: bytes) -> list:
    """Extract all tables from a PDF using Azure AI Document Intelligence.

    Uses the prebuilt-layout analyzer which detects tables, rows, columns,
    headers, and cell content. Authenticates via Azure AD (Managed Identity
    in production, DefaultAzureCredential locally).

    Args:
        pdf_bytes: Raw PDF file bytes.

    Returns:
        A list of table dicts, each with keys: table_index, page, row_count,
        column_count, markdown.
    """
    from azure.ai.documentintelligence import DocumentIntelligenceClient
    from azure.ai.documentintelligence.models import AnalyzeDocumentRequest
    from azure.identity import DefaultAzureCredential

    endpoint = os.environ["DOC_INTEL_ENDPOINT"]
    client = DocumentIntelligenceClient(
        endpoint=endpoint,
        credential=DefaultAzureCredential(),
    )

    request = AnalyzeDocumentRequest(
        bytes_source=base64.b64encode(pdf_bytes).decode("utf-8")
    )

    poller = client.begin_analyze_document(
        "prebuilt-layout",
        body=request,
    )
    result = poller.result()

    tables = []
    if not result.tables:
        logging.info("No tables found in document")
        return tables

    for idx, table in enumerate(result.tables):
        markdown = _table_to_markdown(table)
        page = None
        if table.bounding_regions:
            page = table.bounding_regions[0].page_number

        tables.append({
            "table_index": idx + 1,
            "page": page,
            "row_count": table.row_count,
            "column_count": table.column_count,
            "markdown": markdown,
        })
        logging.info(
            f"Extracted table {idx + 1}: {table.row_count}x{table.column_count} "
            f"on page {page}"
        )

    return tables


def _table_to_markdown(table) -> str:
    """Convert a Document Intelligence table object to a Markdown string."""
    grid = [[""] * table.column_count for _ in range(table.row_count)]
    for cell in table.cells:
        grid[cell.row_index][cell.column_index] = (cell.content or "").strip()

    lines = []
    for i, row in enumerate(grid):
        escaped = [c.replace("|", "\\|") for c in row]
        lines.append("| " + " | ".join(escaped) + " |")
        if i == 0:
            lines.append("| " + " | ".join(["---"] * len(escaped)) + " |")

    return "\n".join(lines)
