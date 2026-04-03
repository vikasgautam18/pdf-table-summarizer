output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "ai_services_endpoint" {
  value = azurerm_cognitive_account.ai_services.endpoint
}

output "doc_intel_endpoint" {
  value = azurerm_cognitive_account.doc_intel.endpoint
}

output "function_app_name" {
  value = azurerm_function_app_flex_consumption.this.name
}

output "function_app_url" {
  value = "https://${azurerm_function_app_flex_consumption.this.default_hostname}"
}

output "function_app_principal_id" {
  description = "Managed Identity principal ID of the Function App"
  value       = azurerm_function_app_flex_consumption.this.identity[0].principal_id
}

output "storage_account_name" {
  value = azurerm_storage_account.this.name
}

output "delta_storage_account_name" {
  description = "ADLS Gen2 storage account name for Delta Tables"
  value       = azurerm_storage_account.delta.name
}

output "delta_container_name" {
  description = "Container name in ADLS Gen2 for Delta Tables"
  value       = azurerm_storage_container.delta_tables.name
}

output "delta_tables_base_path" {
  description = "ADLS Gen2 base path for Delta Tables"
  value       = "abfss://${azurerm_storage_container.delta_tables.name}@${azurerm_storage_account.delta.name}.dfs.core.windows.net/pdf_summarizer"
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "application_insights_name" {
  value = azurerm_application_insights.this.name
}
