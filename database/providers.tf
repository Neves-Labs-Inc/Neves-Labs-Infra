# Runs with management-account credentials (no profile, so AWS_PROFILE works)
# and hops into the member account, so one login is enough.
provider "aws" {
  region = local.region
  # Refuses to run if the assumed role lands in any other account.
  allowed_account_ids = [local.account_id]

  assume_role {
    role_arn = "arn:aws:iam::${local.account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = {
      Project   = "neves-labs"
      ManagedBy = "terraform"
    }
  }
}
