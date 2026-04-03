import os
import logging


SYSTEM_PROMPT = (
    "You are a data analyst. You will be given a table extracted from a PDF document. "
    "Summarize the table concisely in 3-5 sentences. "
    "Highlight key trends, totals, outliers, and notable patterns. "
    "If the table has headers, reference them in your summary. "
    "Do not reproduce the table - only provide the summary."
)


def summarize_table(table_markdown: str, table_index: int) -> str:
    """Summarize a single table using Azure OpenAI GPT-4o via the AI Services endpoint."""
    from openai import AzureOpenAI
    from azure.identity import DefaultAzureCredential, get_bearer_token_provider

    endpoint = os.environ["AI_SERVICES_ENDPOINT"]
    model = os.environ.get("OPENAI_MODEL", "gpt-4o")

    token_provider = get_bearer_token_provider(
        DefaultAzureCredential(),
        "https://cognitiveservices.azure.com/.default"
    )
    client = AzureOpenAI(
        azure_endpoint=endpoint,
        azure_ad_token_provider=token_provider,
        api_version="2024-12-01-preview",
    )

    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": f"Table {table_index}:\n\n{table_markdown}",
            },
        ],
        temperature=0.3,
        max_tokens=500,
    )

    summary = response.choices[0].message.content
    logging.info(f"Summarized table {table_index}: {summary[:80]}...")
    return summary


def summarize_tables(tables: list) -> list:
    """Summarize all extracted tables.

    Args:
        tables: List of table dicts from table_extractor.extract_tables().

    Returns:
        The same list with a 'summary' key added to each table dict.
    """
    for table in tables:
        table["summary"] = summarize_table(
            table["markdown"], table["table_index"]
        )
    return tables
