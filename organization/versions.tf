terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  # Org o-pfm4ezhnh7's management account; the only place this root may run.
  management_account_id = "211125623243"

  common_tags = {
    Project   = "neves-labs"
    ManagedBy = "terraform"
  }
}

# No profile here: the default credential chain applies, so AWS_PROFILE works.
provider "aws" {
  region = var.region
  # Refuses to run if AWS_PROFILE points at any other account.
  allowed_account_ids = [local.management_account_id]

  default_tags {
    tags = local.common_tags
  }
}
