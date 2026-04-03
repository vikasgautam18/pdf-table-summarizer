import os
import logging
from datetime import datetime, timezone


def _get_config():
    """Get ADLS config lazily at call time, not at import time."""
    account = os.environ["DELTA_STORAGE_ACCOUNT_NAME"]
    container = os.environ.get("DELTA_CONTAINER_NAME", "delta-tables")
    base = f"abfss://{container}@{account}.dfs.core.windows.net/pdf_summarizer"
    return {
        "processing_runs": f"{base}/processing_runs",
        "table_summaries": f"{base}/table_summaries",
    }


def _get_storage_options() -> dict:
    """Build storage options for ADLS Gen2 using Managed Identity."""
    from azure.identity import DefaultAzureCredential
    account = os.environ["DELTA_STORAGE_ACCOUNT_NAME"]
    credential = DefaultAzureCredential()
    token = credential.get_token("https://storage.azure.com/.default")
    return {
        "account_name": account,
        "bearer_token": token.token,
        "use_azure_storage_dfs_endpoint": "true",
    }


_tables_verified = set()


def _ensure_tables_exist(storage_options: dict, paths: dict) -> None:
    """Create Delta Tables if they don't exist yet (first-run initialization).

    Only creates if the table truly doesn't exist (TableNotFoundError).
    Transient errors are re-raised to avoid accidentally overwriting data.
    Caches verification to avoid repeated checks within the same process.
    """
    # Skip if already verified in this process lifetime
    tables_key = frozenset(paths.items())
    if tables_key in _tables_verified:
        return
    
    import pyarrow as pa
    from deltalake import write_deltalake, DeltaTable

    for table_name, table_path, schema in [
        ("processing_runs", paths["processing_runs"], pa.schema([
            ("file_name", pa.string()),
            ("site_id", pa.string()),
            ("processed_at", pa.timestamp("us", tz="UTC")),
            ("table_count", pa.int32()),
            ("status", pa.string()),
            ("error_message", pa.string()),
        ])),
        ("table_summaries", paths["table_summaries"], pa.schema([
            ("file_name", pa.string()),
            ("table_index", pa.int32()),
            ("page", pa.int32()),
            ("row_count", pa.int32()),
            ("column_count", pa.int32()),
            ("markdown", pa.string()),
            ("summary", pa.string()),
            ("processed_at", pa.timestamp("us", tz="UTC")),
        ])),
    ]:
        try:
            DeltaTable(table_path, storage_options=storage_options)
        except Exception as e:
            error_str = str(e).lower()
            if "not found" in error_str or "no files in log" in error_str:
                logging.info(f"Creating {table_name} Delta Table")
                empty_table = pa.table(
                    {f.name: pa.array([], type=f.type) for f in schema}
                )
                write_deltalake(
                    table_path,
                    empty_table,
                    mode="error",
                    storage_options=storage_options,
                )
            else:
                raise

    _tables_verified.add(tables_key)


def write_processing_run(
    site_id: str, file_path: str, table_count: int, status: str,
    error_message: str = "",
) -> None:
    """Write a processing run record to the processing_runs Delta Table."""
    import pandas as pd
    from deltalake import write_deltalake

    file_name = file_path.rstrip("/").split("/")[-1]
    now = datetime.now(timezone.utc)

    paths = _get_config()
    storage_options = _get_storage_options()
    _ensure_tables_exist(storage_options, paths)

    df = pd.DataFrame([{
        "file_name": file_name,
        "site_id": site_id,
        "processed_at": now,
        "table_count": table_count,
        "status": status,
        "error_message": error_message,
    }])

    write_deltalake(
        paths["processing_runs"],
        df,
        mode="append",
        storage_options=storage_options,
    )
    logging.info(f"Delta: wrote processing run for {file_name} ({status})")


def is_already_processed(file_path: str) -> bool:
    """Check if a file has been fully processed (run recorded AND summaries written).

    Returns True only if processing_runs has a succeeded entry AND
    table_summaries has at least one entry for this file (or the run
    recorded zero tables).
    """
    from deltalake import DeltaTable

    file_name = file_path.rstrip("/").split("/")[-1]
    paths = _get_config()
    storage_options = _get_storage_options()

    try:
        # Check processing_runs for a succeeded entry
        runs_dt = DeltaTable(paths["processing_runs"], storage_options=storage_options)
        runs_df = runs_dt.to_pandas()
        succeeded = runs_df[
            (runs_df["file_name"] == file_name) & (runs_df["status"] == "succeeded")
        ]
        if len(succeeded) == 0:
            return False

        # Get expected table count from the latest succeeded run
        latest_run = succeeded.sort_values("processed_at", ascending=False).iloc[0]
        expected_tables = int(latest_run["table_count"])

        # If no tables were expected, processing is complete
        if expected_tables == 0:
            return True

        # Check table_summaries has entries for this file
        summaries_dt = DeltaTable(paths["table_summaries"], storage_options=storage_options)
        summaries_df = summaries_dt.to_pandas()
        summary_count = len(summaries_df[summaries_df["file_name"] == file_name])

        return summary_count >= expected_tables
    except Exception:
        return False


def write_table_summaries(file_path: str, tables: list) -> None:
    """Write extracted table summaries to the table_summaries Delta Table."""
    if not tables:
        return

    import pandas as pd
    from deltalake import write_deltalake

    file_name = file_path.rstrip("/").split("/")[-1]
    now = datetime.now(timezone.utc)

    paths = _get_config()
    storage_options = _get_storage_options()
    _ensure_tables_exist(storage_options, paths)

    rows = [
        {
            "file_name": file_name,
            "table_index": t["table_index"],
            "page": t.get("page") or 0,
            "row_count": t["row_count"],
            "column_count": t["column_count"],
            "markdown": t["markdown"],
            "summary": t.get("summary", ""),
            "processed_at": now,
        }
        for t in tables
    ]

    df = pd.DataFrame(rows)

    write_deltalake(
        paths["table_summaries"],
        df,
        mode="append",
        storage_options=storage_options,
    )
    logging.info(f"Delta: wrote {len(tables)} table summary(ies) for {file_name}")


def write_failed_run(site_id: str, file_path: str, error: str) -> None:
    """Record a failed processing run in the Delta Table."""
    write_processing_run(
        site_id=site_id,
        file_path=file_path,
        table_count=0,
        status="failed",
        error_message=error[:500],
    )
