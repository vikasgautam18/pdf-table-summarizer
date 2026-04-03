locals {
  prefix = var.project_name
  tags = {
    project    = "pdf-table-summarizer"
    managed_by = "terraform"
  }
}

# --- Resource Group ----------------------------------------------------------
resource "azurerm_resource_group" "this" {
  name     = "rg-${local.prefix}"
  location = var.location
  tags     = local.tags
}

# --- Storage Account (Function App runtime + Queues + Blob output) -----------
resource "azurerm_storage_account" "this" {
  name                            = "st${local.prefix}"
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  tags = merge(local.tags, {
    SecurityControl = "Ignore"
  })
}

resource "azurerm_storage_queue" "pdf_processing" {
  name               = "pdf-processing"
  storage_account_id = azurerm_storage_account.this.id
}

resource "azurerm_storage_container" "summaries" {
  name                  = "summaries"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# --- ADLS Gen2 Storage Account (Delta Tables) --------------------------------
resource "azurerm_storage_account" "delta" {
  name                            = "${local.prefix}delta"
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  is_hns_enabled                  = true
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  tags = merge(local.tags, {
    purpose         = "delta-tables",
    SecurityControl = "Ignore"
  })
}

resource "azurerm_storage_container" "delta_tables" {
  name                  = var.delta_container_name
  storage_account_id    = azurerm_storage_account.delta.id
  container_access_type = "private"
}

# --- Azure AI Services (OpenAI + Document Intelligence) ----------------------
resource "azurerm_cognitive_account" "ai_services" {
  name                  = "${local.prefix}-ai-services"
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = "${local.prefix}-oai"
  tags                  = local.tags

  identity {
    type = "SystemAssigned"
  }
}

# --- GPT-4o Model Deployment (via AI Services) -------------------------------
resource "azurerm_cognitive_deployment" "gpt4o" {
  name                 = "gpt-4o"
  cognitive_account_id = azurerm_cognitive_account.ai_services.id

  model {
    format  = "OpenAI"
    name    = "gpt-4o"
    version = "2024-11-20"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 30
  }
}

# --- Document Intelligence (Central India) -----------------------------------
# prebuilt-layout is available in Central India and supports table extraction.
resource "azurerm_cognitive_account" "doc_intel" {
  name                  = "${local.prefix}-doc-intel"
  location              = "centralindia"
  resource_group_name   = azurerm_resource_group.this.name
  kind                  = "FormRecognizer"
  sku_name              = "S0"
  custom_subdomain_name = "${local.prefix}-doc-intel"
  tags                  = local.tags

  identity {
    type = "SystemAssigned"
  }
}

# --- Key Vault ---------------------------------------------------------------
resource "azurerm_key_vault" "this" {
  name                       = "kv-${local.prefix}"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = var.graph_tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  rbac_authorization_enabled = true
  tags                       = local.tags
}

# --- Key Vault Secret: Graph Client Secret -----------------------------------
resource "azurerm_key_vault_secret" "graph_client_secret" {
  name         = "graph-client-secret"
  value        = var.graph_client_secret
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.deployer_kv_admin]
}

# --- RBAC: Current deployer -> Key Vault Administrator -----------------------
# Needed so Terraform can create secrets in Key Vault
data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "deployer_kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# --- Application Insights ----------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = "law-${local.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${local.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "other"
  tags                = local.tags
}

# --- Storage container for Flex Consumption deployment -----------------------
resource "azurerm_storage_container" "deployments" {
  name                  = "deployments"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# --- Service Plan (Flex Consumption) -----------------------------------------
resource "azurerm_service_plan" "this" {
  name                = "asp-${local.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = local.tags
}

# --- Azure Function App (Flex Consumption) -----------------------------------
resource "azurerm_function_app_flex_consumption" "this" {
  name                = "func-${local.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  service_plan_id     = azurerm_service_plan.this.id
  tags                = local.tags

  runtime_name    = "python"
  runtime_version = "3.11"

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.this.primary_blob_endpoint}${azurerm_storage_container.deployments.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.this.primary_access_key

  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string
  }

  always_ready {
    name           = "function:process_pdf"
    instance_count = 1
  }

  app_settings = {
    "AzureWebJobsStorage"              = azurerm_storage_account.this.primary_connection_string
    "AzureWebJobsFeatureFlags"         = "EnableWorkerIndexing"
    "GRAPH_TENANT_ID"                  = var.graph_tenant_id
    "GRAPH_CLIENT_ID"                  = var.graph_client_id
    "GRAPH_CLIENT_SECRET"              = var.graph_client_secret
    "DOC_INTEL_ENDPOINT"               = azurerm_cognitive_account.doc_intel.endpoint
    "AI_SERVICES_ENDPOINT"             = azurerm_cognitive_account.ai_services.endpoint
    "OPENAI_MODEL"                     = "gpt-4o"
    "DELTA_STORAGE_ACCOUNT_NAME"       = azurerm_storage_account.delta.name
    "DELTA_CONTAINER_NAME"             = var.delta_container_name
    "ENABLE_BLOB_OUTPUT"               = var.enable_blob_output ? "true" : "false"
    "SHAREPOINT_SITE_ID"               = var.sharepoint_site_id
    "WEBHOOK_CLIENT_STATE"             = var.webhook_client_state
    "MAX_PDF_SIZE_MB"                  = tostring(var.max_pdf_size_mb)
    "SUMMARIES_CONTAINER"              = azurerm_storage_container.summaries.name
    "SUMMARIES_STORAGE_CONNECTION_STR" = azurerm_storage_account.this.primary_connection_string
  }

  identity {
    type = "SystemAssigned"
  }
}

# --- RBAC: Function App MI -> ADLS Gen2 Storage Blob Data Contributor --------
resource "azurerm_role_assignment" "func_delta_blob_contributor" {
  scope                = azurerm_storage_account.delta.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_function_app_flex_consumption.this.identity[0].principal_id
}

# --- RBAC: Function App MI -> Blob Storage Data Contributor ------------------
resource "azurerm_role_assignment" "func_blob_contributor" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_function_app_flex_consumption.this.identity[0].principal_id
}

# --- RBAC: Function App MI -> Key Vault Secrets User -------------------------
resource "azurerm_role_assignment" "func_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_function_app_flex_consumption.this.identity[0].principal_id
}

# --- RBAC: Function App MI -> Cognitive Services User (AI Services) ----------
resource "azurerm_role_assignment" "func_ai_services_user" {
  scope                = azurerm_cognitive_account.ai_services.id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_function_app_flex_consumption.this.identity[0].principal_id
}

# --- RBAC: Function App MI -> Cognitive Services User (Doc Intel) ------------
resource "azurerm_role_assignment" "func_doc_intel_user" {
  scope                = azurerm_cognitive_account.doc_intel.id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_function_app_flex_consumption.this.identity[0].principal_id
}
