provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "genai-assistant"
      Component = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}
