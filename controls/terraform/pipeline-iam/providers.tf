provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "genai-assistant"
      Component = "pipeline-iam"
      ManagedBy = "terraform"
    }
  }
}
