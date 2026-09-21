# pipeline-iam

The one root that runs from a laptop, once, before the pipeline exists.

It creates the three things `infra-provision.yml` and `infra-destroy.yml` need and cannot
create for themselves:

| resource | why the pipeline can't create it |
|---|---|
| S3 state bucket + CMK | the pipeline's own state lives in it |
| GitHub OIDC provider | it is what lets the pipeline authenticate at all |
| deploy role | the role the pipeline assumes |

It keeps **local state**, deliberately — a root that creates the state bucket
cannot store its state there. Its three resources are created once and never
change, so losing the state file costs a `terraform import`, not an outage.

## Running it

```bash
cd controls/terraform/pipeline-iam
cp terraform.tfvars.example terraform.tfvars   # fill in bucket name and repo
terraform init
terraform apply                                 # needs admin credentials, once
```

Then set the two outputs as **repository variables** (Settings → Secrets and
variables → Actions → Variables):

| variable | value |
|---|---|
| `TF_STATE_BUCKET` | `terraform output -raw state_bucket` |
| `AWS_DEPLOY_ROLE_ARN` | `terraform output -raw deploy_role_arn` |
| `COST_ALERT_EMAIL` | optional; where the budget alarm goes |

And create an Actions **environment** named `production`. The name is not
cosmetic: the role's trust policy pins `environment:production` in the OIDC
subject, so a job without that block receives a token AWS will not accept.

## Two things worth knowing

**One OIDC provider per AWS account, not per repository.** If the account
already has `token.actions.githubusercontent.com`, set
`create_oidc_provider = false` and pass `existing_oidc_provider_arn` rather
than creating a second one.

**The deploy role's infrastructure policy is service-scoped, not
resource-scoped.** The roots create VPCs, clusters, keys and roles whose ARNs
do not exist until the first apply, so resource-level ARNs cannot be written
ahead of it. The tightening step — replace the wildcards with the ARNs that
first apply produced — is a deliberate follow-up, and it is named in the risk
assessment rather than hidden here. What *is* already scoped: the role cannot
edit its own trust policy, and cannot touch the OIDC provider.
