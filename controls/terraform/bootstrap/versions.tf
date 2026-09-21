terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # This root deliberately keeps local state.
  #
  # It is the root that CREATES the remote state bucket, so it cannot store its
  # own state there. Its state describes three long-lived resources that are
  # created once and never change; the RUNBOOK says to commit nothing and keep
  # the file, and losing it costs an import, not an outage.
}
