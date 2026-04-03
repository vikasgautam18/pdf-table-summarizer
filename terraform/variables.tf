variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
}

variable "project_name" {
  description = "Short project name used as prefix for resources"
  type        = string
}

variable "graph_tenant_id" {
  description = "Entra ID tenant ID for Graph API access"
  type        = string
}

variable "graph_client_id" {
  description = "Entra ID app client ID for Graph API access"
  type        = string
}

variable "graph_client_secret" {
  description = "Entra ID app client secret for Graph API access"
  type        = string
  sensitive   = true
}

variable "sharepoint_site_id" {
  description = "SharePoint site ID for webhook notifications"
  type        = string
}

variable "delta_container_name" {
  description = "Container name in ADLS Gen2 for Delta Tables"
  type        = string
}

variable "enable_blob_output" {
  description = "Enable secondary Blob Storage JSON output alongside Delta Tables"
  type        = bool
}

variable "webhook_client_state" {
  description = "Shared secret for verifying SharePoint webhook notifications"
  type        = string
}

variable "max_pdf_size_mb" {
  description = "Maximum allowed PDF file size in MB (prevents memory exhaustion)"
  type        = number
}
