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

# The jump host fetches rendered manifests and a kubectl binary from the state
# bucket, because it has an S3 gateway endpoint and no route to anything else.
# Offline the variable is empty, which leaves it with no S3 grant at all.
if [ "${key}" = "eks-platform" ]; then
  echo "deploy_staging_bucket_arn = \"arn:aws:s3:::${bucket}\"" >> "${dir}/ci.auto.tfvars"

  # The bucket is CMK-encrypted, so reading from it needs kms:Decrypt as well
  # as s3:GetObject. Empty when the bucket was made elsewhere with an AWS
  # managed key, which needs no grant.
  if [ -n "${TF_STATE_KMS_KEY_ARN:-}" ]; then
    echo "deploy_staging_kms_key_arn = \"${TF_STATE_KMS_KEY_ARN}\"" >> "${dir}/ci.auto.tfvars"
  fi
fi

# This account exists to be provisioned and torn down again, so two resources
# that would otherwise refuse to be deleted are allowed to be: the CloudTrail
# bucket with its object versions still in it, and the container registry with
# images still in it. Both defaults are false in their modules, deliberately --
# an audit log store and a registry holding what production runs *should* refuse
# a terraform destroy. Here they strand the teardown instead, and a teardown
# that stops half way leaves the expensive resources running.
if [ "${key}" = "bedrock-ai" ] || [ "${key}" = "eks-platform" ]; then
  echo "ephemeral_environment = true" >> "${dir}/ci.auto.tfvars"
fi

if [ "${key}" = "eks-platform" ] && [ -n "${COST_ALERT_EMAIL:-}" ]; then
  echo "cost_alert_emails = [\"${COST_ALERT_EMAIL}\"]" >> "${dir}/ci.auto.tfvars"
fi

# Cluster admin is granted to named principals and inherited by nobody: the
# cluster sets bootstrap_cluster_creator_admin_permissions to false, so the
# deploy role does not become an administrator by virtue of having run apply.
# The consequence is that a human with no access entry gets "Unauthorized" in
# the EKS console against Pods and Nodes, because the console calls the
# Kubernetes API as the signed-in principal rather than as the cluster owner.
# Comma-separated so one repository variable can carry several operators.
if [ "${key}" = "eks-platform" ] && [ -n "${CLUSTER_ADMIN_ARNS:-}" ]; then
  arns="$(printf '%s' "${CLUSTER_ADMIN_ARNS}" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' \
    | sed 's/.*/"&"/' \
    | paste -sd, -)"
  echo "cluster_admin_principal_arns = [${arns}]" >> "${dir}/ci.auto.tfvars"
fi

# The jump host AMI. Terraform could read this from an aws_ssm_parameter data
# source in one line, and that line would make `terraform plan` require AWS
# credentials, which is the one thing this repository will not do. Resolving it
# here keeps the roots free of data sources that call AWS.
# An account holds at most one dimensional SERVICE anomaly monitor, and AWS
# creates a default one the first time Cost Explorer is opened. Creating a
# second fails with "Limit exceeded on dimensional spend monitor creation", so
# the existing one is reused where there is one.
if [ "${key}" = "eks-platform" ]; then
  monitor="$(aws ce get-anomaly-monitors \
    --query "AnomalyMonitors[?MonitorType=='DIMENSIONAL' && MonitorDimension=='SERVICE'] | [0].MonitorArn" \
    --output text 2>/dev/null || echo None)"
  if [ "${monitor}" != "None" ] && [ -n "${monitor}" ]; then
    echo "existing_anomaly_monitor_arn = \"${monitor}\"" >> "${dir}/ci.auto.tfvars"
  fi
fi

# The S3 gateway endpoint is reached by route, so the node security group needs
# a prefix list egress rule for it. The ID is regional and not guessable.
if [ "${key}" = "eks-platform" ]; then
  prefix_list="$(aws ec2 describe-prefix-lists \
    --region "${region}" \
    --filters "Name=prefix-list-name,Values=com.amazonaws.${region}.s3" \
    --query "PrefixLists[0].PrefixListId" --output text)"
  echo "s3_prefix_list_id = \"${prefix_list}\"" >> "${dir}/ci.auto.tfvars"
fi

if [ "${key}" = "eks-platform" ]; then
  ami="$(aws ssm get-parameter \
    --region "${region}" \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text)"
  echo "bastion_ami_id = \"${ami}\"" >> "${dir}/ci.auto.tfvars"
fi

echo "${dir}: backend -> s3://${bucket}/${key}/terraform.tfstate (${state_region}), account ${account_id}, deploying to ${region}"
