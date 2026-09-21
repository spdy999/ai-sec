variable "region" {
  description = "Region holding the state bucket and the deploy role."
  type        = string
  default     = "eu-central-1"
}

variable "state_bucket_name" {
  description = "Globally unique name for the Terraform state bucket."
  type        = string
}

variable "github_owner" {
  description = "GitHub user or organisation that owns the repository."
  type        = string
}

variable "github_repository" {
  description = "Repository name, without the owner."
  type        = string
}

# The trust policy pins the environment, not just the branch. A workflow job
# only receives a token with this subject if it declares `environment: production`,
# so a job added without that line cannot assume the role at all.
variable "github_environment" {
  description = "GitHub Actions environment whose jobs may assume the deploy role."
  type        = string
  default     = "production"
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider, used when create_oidc_provider is false."
  type        = string
  default     = ""
}
