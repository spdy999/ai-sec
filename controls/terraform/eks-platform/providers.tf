provider "aws" {
  region = var.region

  # Offline plan: the graph renders with no AWS account and no credentials, so a
  # reviewer can reproduce the gate for free. The provider still resolves
  # credentials during plan even with every skip_* flag set, so mock static keys
  # are supplied. A real deployment sets offline_plan = false and authenticates
  # through OIDC.
  skip_credentials_validation = var.offline_plan
  skip_requesting_account_id  = var.offline_plan
  skip_metadata_api_check     = var.offline_plan
  skip_region_validation      = var.offline_plan

  access_key = var.offline_plan ? "mock-access-key" : null
  secret_key = var.offline_plan ? "mock-secret-key" : null

  default_tags {
    tags = {
      Project            = "koerber-genai-assistant"
      Layer              = "platform"
      Environment        = var.environment
      DataClassification = "confidential"
      DataResidency      = "eu"
      ManagedBy          = "terraform"
    }
  }
}
