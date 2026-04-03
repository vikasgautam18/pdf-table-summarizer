import azure.functions as func
import json
import logging

from functions.webhook_handler import webhook_handler_impl
from functions.process_pdf import process_pdf_impl

app = func.FunctionApp()


@app.route(route="webhook", methods=["GET", "POST"], auth_level=func.AuthLevel.FUNCTION)
def webhook_handler(req: func.HttpRequest) -> func.HttpResponse:
    """HTTP-triggered function that handles SharePoint webhook notifications.

    - On subscription validation: echoes the validationtoken query param.
    - On change notification: enqueues file metadata to the pdf-processing queue.
    """
    return webhook_handler_impl(req)


@app.queue_trigger(arg_name="msg", queue_name="pdf-processing",
                   connection="AzureWebJobsStorage")
def process_pdf(msg: func.QueueMessage) -> None:
    """Queue-triggered function that processes a PDF from SharePoint.

    Pipeline steps:
    1. Download PDF from SharePoint via Graph API
    2. Extract tables using Document Intelligence (prebuilt-layout)
    3. Summarize each table with Azure OpenAI GPT-4o
    4. Store results as Delta Tables on ADLS Gen2
    5. Optionally store results as JSON in Azure Blob Storage
    """
    try:
        process_pdf_impl(msg)
    except Exception as e:
        logging.error(f"Failed to process PDF: {e}", exc_info=True)
        try:
            from functions.delta_writer import write_failed_run
            payload = json.loads(msg.get_body().decode("utf-8"), strict=False)
            write_failed_run(
                payload.get("siteId", "unknown"),
                payload.get("filePath", "unknown"),
                str(e),
            )
        except Exception:
            logging.error("Failed to record error in Delta Tables", exc_info=True)
        raise
