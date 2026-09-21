#!/usr/bin/env bash
#
# Writes the two files a real deployment needs and the repository deliberately
# does not commit: the S3 backend, and the variables that turn off offline mode.
#
# The backend block is generated rather than committed because declaring a
# backend makes `terraform plan` refuse to run without it:
#
#   Error: Backend initialization required, please run "terraform init"
#   Reason: Initial configuration of the requested backend "s3"
#
# That would break `make plan`, `make ci` and the whole offline story, which is
# the property the assignment is built on. State lives in S3 for deployments
# and nowhere for gates.
#
# Usage: tf-config.sh <root directory> <state key prefix>

set -euo pipefail

dir="${1:?usage: tf-config.sh <root directory> <state key prefix>}"
key="${2:?usage: tf-config.sh <root directory> <state key prefix>}"

: "${TF_STATE_BUCKET:?set the TF_STATE_BUCKET repository variable to the state bucket name}"

region="${AWS_REGION:-eu-central-1}"

# The backend's `bucket` is a name, not an ARN, and the two are easy to confuse
# when copying out of the console. Accept either and normalise, rather than
# failing later inside `terraform init` with a message that does not say why.
bucket="${TF_STATE_BUCKET#arn:aws:s3:::}"

# The backend's `region` must be the bucket's own region, which is not
# necessarily where the infrastructure is deployed. Override only when they
# differ.
state_region="${TF_STATE_REGION:-${region}}"

# The account id is read from the assumed session rather than configured. One
# less value to keep in sync, and it cannot disagree with the role that is
# actually being used.
account_id="$(aws sts get-caller-identity --query Account --output text)"

# use_lockfile is S3 native locking, which needs Terraform 1.10 or newer. It
# replaces the DynamoDB lock table: one less resource to create, pay for and
# forget to destroy.
cat > "${dir}/backend.tf" <<EOF
terraform {
  backend "s3" {
    bucket       = "${bucket}"
    key          = "${key}/terraform.tfstate"
    region       = "${state_region}"
    encrypt      = true
    use_lockfile = true
  }
}
EOF

cat > "${dir}/ci.auto.tfvars" <<EOF
offline_plan = false
account_id   = "${account_id}"
region       = "${region}"
EOF

if [ "${key}" = "eks-platform" ] && [ -n "${COST_ALERT_EMAIL:-}" ]; then
  echo "cost_alert_emails = [\"${COST_ALERT_EMAIL}\"]" >> "${dir}/ci.auto.tfvars"
fi

echo "${dir}: backend -> s3://${bucket}/${key}/terraform.tfstate (${state_region}), account ${account_id}, deploying to ${region}"
