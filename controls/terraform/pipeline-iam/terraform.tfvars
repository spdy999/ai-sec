# The one-time bootstrap input: which AWS account and which repository the
# pipeline is being wired between. Committed, unlike every other tfvars file
# here, because it holds no secrets and because a clone that cannot reproduce
# this has to guess it.
#
# Changing the account is not just this file. All of the following must agree,
# or the deploy role is created in one account and assumed against another:
#
#   1. account_id and state_bucket_name below
#   2. backend.tf in this directory, which names the state bucket
#   3. the AWS_DEPLOY_ROLE_ARN and TF_STATE_BUCKET repository variables
#   4. CLUSTER_ADMIN_ARNS, which names a principal in that account
#
# The state bucket must exist before backend.tf can point at it, so the first
# apply in a new account runs with local state; see README.md.
account_id        = "891377211626"
state_bucket_name = "genai-assistant-tfstate-891377211626"

# True in a fresh account, where this root creates the bucket. False if the
# bucket already exists and was made by hand, in which case import it rather
# than letting a second apply try to create it again.
create_state_bucket = true

github_owner      = "spdy999"
github_repository = "ai-sec"

# Numeric IDs, from `gh api users/spdy999 --jq .id` and
# `gh api repos/spdy999/ai-sec --jq .id`. GitHub's immutable OIDC subject
# carries them so that renaming the account or the repository cannot transfer
# trust to whoever claims the old name.
github_owner_id      = "24741707"
github_repository_id = "1376188734"
