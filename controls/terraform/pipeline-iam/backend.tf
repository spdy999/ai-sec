# This root's state is remote like the others. It can be: it runs with a
# person's own credentials, not the role it creates, so there is no circularity
# - only an ordering requirement that the bucket exists first.
#
# The bucket name has to match state_bucket_name in terraform.tfvars, and both
# have to match the account the credentials belong to. A backend naming one
# account's bucket while the variables name another's is the failure that looks
# like a permissions problem: terraform reads state that describes resources
# which do not exist where it is about to create them.
#
# In a brand new account this file has to be moved aside for the first apply,
# because the bucket it names is what that apply creates. See README.md.
terraform {
  backend "s3" {
    bucket       = "genai-assistant-tfstate-891377211626"
    key          = "pipeline-iam/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
