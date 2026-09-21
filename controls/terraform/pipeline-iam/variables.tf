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

variable "create_state_bucket" {
  description = "Create the state bucket, its CMK and its policies. Set false when the bucket already exists."
  type        = bool
  default     = true
}

variable "state_kms_key_arn" {
  description = "CMK encrypting a pre-existing state bucket, if it has one. Only read when create_state_bucket is false."
  type        = string
  default     = ""
}

variable "account_id" {
  description = "AWS account the role and providers live in."
  type        = string
}

variable "name_prefix" {
  description = "Prefix on the roles and policies Terraform creates. Must match the roots' name_prefix."
  type        = string
  default     = "genai-assistant"
}

variable "deploy_role_name" {
  description = "Name of the role GitHub Actions assumes."
  type        = string
  default     = "genai-assistant-gh-pipeline-role"
}

variable "github_owner_id" {
  description = "Numeric account ID of the owner, from `gh api users/<owner> --jq .id`. Part of the immutable OIDC subject, which embeds IDs so renaming an account cannot transfer trust."
  type        = string
}

variable "github_repository_id" {
  description = "Numeric repository ID, from `gh api repos/<owner>/<repo> --jq .id`. Same reason."
  type        = string
}
