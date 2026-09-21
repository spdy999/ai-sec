# This root's state is remote like the others. It can be: it runs with a
# person's own credentials, not the role it creates, so there is no circularity
# - only an ordering requirement that the bucket exists first.
terraform {
  backend "s3" {
    bucket       = "genai-assistant-tfstate-171414227044"
    key          = "pipeline-iam/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
